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
download_root=""
helper=""

cleanup() {
  [[ -n $download_root ]] && rm -rf "$download_root"
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

# Recovery must not create a snapshot, import keys, or change repositories and
# only then discover a missing preflight interpreter on an older installation.
if (( ! dry_run )); then
  for tool in python3 curl bsdtar git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Recovery requires $tool. Install python, curl, libarchive and git before retrying." >&2
      exit 1
    fi
  done
fi

# One source of truth for what the repository and key must be. A checkout has
# the helper next to this script; an installed machine has it under the package
# once it is new enough. Neither is guaranteed on the machines this script
# exists for, so fall back to fetching it rather than restating its contents.
resolve_helper() {
  local script_dir="" candidate helper_url="$HELPER_URL" source_sha

  if [[ -f ${BASH_SOURCE[0]} ]]; then
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  fi

  for candidate in "$script_dir" "${OMARCHY_PATH:-}" /usr/share/omarchy; do
    if [[ -n $candidate && -f "$candidate/$HELPER_RELATIVE_PATH" && -f "$candidate/install/helpers/arm-channel-manifest.py" ]]; then
      helper="$candidate/$HELPER_RELATIVE_PATH"
      return 0
    fi
  done

  if [[ -z ${OMARCHY_ARM_HELPER_URL:-} ]]; then
    source_sha=$(git ls-remote https://github.com/omarchy-mac/omarchy-mac.git refs/heads/quattro | awk '{print $1}') || return
    [[ $source_sha =~ ^[0-9a-f]{40}$ ]] || return 1
    helper_url="https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/$source_sha/$HELPER_RELATIVE_PATH"
  fi
  download_root=$(mktemp -d)
  mkdir -p "$download_root/install/helpers"
  downloaded_helper="$download_root/$HELPER_RELATIVE_PATH"
  if curl -fsSL "$helper_url" -o "$downloaded_helper"; then
    helper="$downloaded_helper"
    if (( ! dry_run )); then
      curl -fsSL "${helper_url%/*}/arm-channel-manifest.py" -o "$download_root/install/helpers/arm-channel-manifest.py" || return
    fi
    return 0
  fi

  rm -f "$downloaded_helper"
  downloaded_helper=""
  return 1
}

if ! resolve_helper; then
  echo "Could not find or fetch $HELPER_RELATIVE_PATH" >&2
  exit 1
fi
# shellcheck source=install/helpers/arm-package-sources.sh
source "$helper"
helper_root=$(cd -- "$(dirname -- "$helper")/../.." && pwd)

mapfile -t targets < <(omarchy_arm_package_targets)

if (( dry_run )); then
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
  omarchy_arm_validate_channel() { echo "would validate published $1 snapshot"; }
  omarchy_arm_prepare_package_sources "$preview" preserve-backup "" "$helper_root"
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
if ! omarchy_arm_prepare_package_sources "$PACMAN_CONF" backup "" "$helper_root"; then
  echo "Could not prepare package sources" >&2
  exit 1
fi

# OMARCHY_UPDATE_PACMAN=1 is what the update guard hook reads to tell an
# Omarchy-driven transaction from someone reaching past `omarchy update`. This
# is that path arriving by another route, not a bypass, so it says so the same
# way omarchy-update-system-pkgs does. Without it the hook aborts the
# transaction and the recovery gets no further than the machine it is fixing.
echo "Updating the Hyprland stack together with the system"
sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu --noconfirm "${targets[@]}"

cat <<'EOF'

Hyprland was replaced underneath the running session. Log out and back in
before anything else, then run `omarchy update` normally.
EOF
