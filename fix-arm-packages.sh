#!/bin/bash
# fix-arm-packages.sh
# Recover an Apple Silicon install that cannot update because the Hyprland
# stack in the regular repositories no longer matches the Aquamarine ABI there.
#
# The permanent fix ships inside the omarchy package, in
# install/helpers/arm-package-sources.sh, and runs from the installer and the
# update commands. A machine installed before that fix can reach neither: the
# installer is over, and the update aborts in dependency resolution before the
# package carrying the helper can be replaced. This script applies the same
# preparation from outside the package so that update can start again.
#
# Usage: bash fix-arm-packages.sh [--dry-run] [--no-snapshot]

set -euo pipefail

readonly HELPER_RELATIVE_PATH="install/helpers/arm-package-sources.sh"
readonly HELPER_URL="${OMARCHY_ARM_HELPER_URL:-https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/$HELPER_RELATIVE_PATH}"
readonly PACMAN_CONF="${OMARCHY_ARM_PACMAN_CONF:-/etc/pacman.conf}"

dry_run=0
snapshot=1
downloaded_helper=""
helper=""

cleanup() {
  [[ -n $downloaded_helper ]] && rm -f "$downloaded_helper"
  return 0
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: bash $0 [--dry-run] [--no-snapshot]

Options:
  --dry-run      Report the configuration change and the transaction without applying either.
  --no-snapshot  Skip the Snapper snapshot taken before the transaction.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --no-snapshot)
      snapshot=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# The transaction is Apple Silicon's; a dry run is a report and is allowed to
# run anywhere, which is also what keeps this script under test off a Mac.
if (( ! dry_run )) && [[ $(uname -m) != "aarch64" ]]; then
  echo "This recovery is for Apple Silicon installs only (detected: $(uname -m))" >&2
  exit 1
fi

if [[ ! -f $PACMAN_CONF ]]; then
  echo "No pacman configuration at $PACMAN_CONF" >&2
  exit 1
fi

# One source of truth for what the repository and key must be. A checkout has
# the helper next to this script and is used as is. Otherwise fetch the
# published copy first: the helper installed under the package is the one this
# script exists to get past, and on a stuck machine it still selects targets edge
# no longer publishes. The installed copy is only a fallback for when the fetch
# fails, since a current one still recovers and a stale one fails no worse.
resolve_helper() {
  local script_dir="" candidate

  if [[ -f ${BASH_SOURCE[0]} ]]; then
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  fi

  if [[ -n $script_dir && -f "$script_dir/$HELPER_RELATIVE_PATH" ]]; then
    helper="$script_dir/$HELPER_RELATIVE_PATH"
    return 0
  fi

  downloaded_helper=$(mktemp)
  if curl -fsSL "$HELPER_URL" -o "$downloaded_helper"; then
    helper="$downloaded_helper"
    return 0
  fi
  rm -f "$downloaded_helper"
  downloaded_helper=""

  for candidate in "${OMARCHY_PATH:-}" /usr/share/omarchy; do
    if [[ -n $candidate && -f "$candidate/$HELPER_RELATIVE_PATH" ]]; then
      echo -e "\e[33mCould not fetch $HELPER_URL; using the installed $candidate/$HELPER_RELATIVE_PATH\e[0m" >&2
      helper="$candidate/$HELPER_RELATIVE_PATH"
      return 0
    fi
  done

  return 1
}

if ! resolve_helper; then
  echo "Could not find or fetch $HELPER_RELATIVE_PATH" >&2
  exit 1
fi
# shellcheck source=install/helpers/arm-package-sources.sh
source "$helper"

# stdin is the script itself when piped, so nothing here may read it.
choose_targets() {
  mapfile -t targets < <(OMARCHY_PACMAN_CONFIG="$PACMAN_CONF" omarchy_arm_package_targets </dev/null)
}

if (( dry_run )); then
  # A dry run syncs nothing, so it reports the selection the databases on the
  # machine give now; on a machine that never synced [omarchy], that is every target.
  choose_targets
  preview=$(mktemp)
  cp "$PACMAN_CONF" "$preview"
  # Nothing leaves the temporary copy: the helper's writes land there as this
  # user, and the key import is reported instead of performed.
  sudo() {
    if [[ $1 == "pacman-key" ]]; then
      echo "would run: sudo $*"
    else
      command "$@"
    fi
  }
  omarchy_arm_prepare_package_sources "$preview" preserve-backup
  echo "Configuration change for $PACMAN_CONF:"
  diff -u "$PACMAN_CONF" "$preview" || true
  rm -f "$preview" "$preview.bak"
  echo "would run: sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu --noconfirm ${targets[*]}"
  exit 0
fi

# Before anything is written, so the snapshot is of the machine as found. 127
# means Snapper is deliberately absent, the same reading omarchy-update takes;
# a missing snapshot is not worth refusing the recovery over.
if (( snapshot )) && command -v omarchy-snapshot >/dev/null; then
  omarchy-snapshot create || (( $? == 127 )) ||
    echo -e "\e[33mContinuing without a snapshot.\e[0m" >&2
fi

echo "Preparing package sources"
if ! omarchy_arm_prepare_package_sources "$PACMAN_CONF"; then
  echo "Could not prepare package sources" >&2
  exit 1
fi

# OMARCHY_UPDATE_PACMAN=1 is what the update guard hook reads to tell an
# Omarchy-driven transaction from someone reaching past `omarchy update`. This
# is that path arriving by another route, not a bypass, so it says so the same
# way omarchy-update-system-pkgs does. Without it the hook aborts the
# transaction and the recovery gets no further than the machine it is fixing.
# The selection follows what the synced [omarchy] database carries, and a
# machine that predates this policy has never synced it: without this the
# helper selects every target and the transaction stops at the ones edge no
# longer publishes. The -Syu follows straight after.
sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Sy --noconfirm </dev/null
choose_targets

echo "Updating the Hyprland stack together with the system"
sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu --noconfirm "${targets[@]}"

cat <<'EOF'

Hyprland was replaced underneath the running session. Log out and back in
before anything else, then run `omarchy update` normally.
EOF
