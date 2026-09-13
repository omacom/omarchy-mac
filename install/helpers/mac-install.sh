#!/bin/bash

# Fresh Omarchy 4 install for Apple Silicon.
#
# Upstream installs Omarchy 4 from the ISO, which has no aarch64 build and
# cannot boot an Apple Silicon Mac anyway. Normal installs use the published
# ARM packages; --from-source builds this checkout for development.

set -euo pipefail

readonly checkout="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly package_output="$checkout/build-output"
readonly asahi_alarm_key="12CE6799A94A3F1B5DDFFE88F576553597FB8FEB"
source "$checkout/install/helpers/arm-package-sources.sh"

# gum is how the rest of Omarchy talks to people, but it arrives with the
# omarchy package well into this script, so every helper falls back to plain
# output until ensure_gum has run.
log() {
  if command -v gum >/dev/null 2>&1; then
    gum style --bold --foreground 2 "==> $*"
  else
    printf '\033[32m==>\033[0m %s\n' "$*"
  fi
}

warn() {
  if command -v gum >/dev/null 2>&1; then
    gum style --bold --foreground 3 "Warning: $*" >&2
  else
    printf '\033[33mWarning:\033[0m %s\n' "$*" >&2
  fi
}

fail() {
  if command -v gum >/dev/null 2>&1; then
    gum style --bold --foreground 1 "Error: $*" >&2
  else
    printf '\033[31mError:\033[0m %s\n' "$*" >&2
  fi
  exit 1
}

# Asahi Alarm ships LANG=C, and nothing else in the install path replaces it.
ensure_utf8_locale() {
  source "$checkout/install/preflight/locale.sh"
}

ensure_gum() {
  command -v gum >/dev/null 2>&1 && return 0

  # Installed up front rather than waiting for the omarchy package, so the
  # whole install looks like Omarchy instead of only its last third.
  sudo pacman -S --needed --noconfirm gum >/dev/null 2>&1 ||
    warn "Could not install gum; falling back to plain output."
}

check_preconditions() {
  (( EUID != 0 )) || fail "Run this as your regular user, not as root. It uses sudo where needed."
  [[ $(uname -m) == "aarch64" ]] || fail "This is the Apple Silicon installer. On x86 machines install from the ISO."
  command -v pacman >/dev/null || fail "This installer only supports Arch-based systems."
  command -v sudo >/dev/null || fail "sudo is required."
  grep -qi apple /proc/device-tree/compatible 2>/dev/null ||
    warn "This does not look like Apple hardware; continuing anyway."
}

ensure_aur_helper() {
  command -v yay >/dev/null && return 0

  log "Installing yay (needed for the AUR packages in the default set)"
  sudo pacman -S --needed --noconfirm git base-devel
  local workspace
  workspace="$(mktemp -d)"
  git clone https://aur.archlinux.org/yay.git "$workspace/yay"
  (cd "$workspace/yay" && makepkg -si --noconfirm --needed)
  rm -rf "$workspace"
}

ensure_package_sources() {
  # A fresh machine has no omarchy-pkgs checkout, and build-packages.sh needs
  # the PKGBUILDs. Respect an existing one so a developer can build offline.
  if [[ -n ${OMARCHY_PKGS_PATH:-} && -d ${OMARCHY_PKGS_PATH:-} ]]; then
    return 0
  fi

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-build"
  local pkgs_checkout="$cache_dir/omarchy-pkgs"

  if [[ -d $pkgs_checkout/.git ]]; then
    log "Updating the PKGBUILD checkout"
    git -C "$pkgs_checkout" pull --ff-only || warn "Could not update $pkgs_checkout; using it as is."
  else
    log "Cloning the PKGBUILD checkout"
    mkdir -p "$cache_dir"
    git clone --depth 1 https://github.com/omacom/omarchy-pkgs.git "$pkgs_checkout"
  fi

  export OMARCHY_PKGS_PATH="$pkgs_checkout"
}

build_omarchy_packages() {
  log "Building the Omarchy packages from this checkout"
  OMARCHY_PACKAGE_OUTPUT="$package_output" "$checkout/build-packages.sh"
}

install_omarchy_packages() {
  log "Installing the Omarchy packages"

  local artifact
  local -a built=()
  for artifact in "$package_output"/*.pkg.tar.*; do
    [[ -f $artifact && $artifact != *.sig ]] || continue
    built+=("$artifact")
  done
  (( ${#built[@]} )) || fail "No packages were built in $package_output."
  # A rebuilt checkout can keep the same package version. Replace the payload
  # so the installed helper really is the code we just built.
  sudo pacman -U --noconfirm "${built[@]}"
}

# Resolve only explicit ARM repository targets. Other repositories may carry
# identically named packages with an x86 boot configuration or a different source.
install_prebuilt_omarchy_packages() {
  local metadata repository package version architecture filename archive info helper settings_files
  local -a targets=(omarchy-aarch64/omarchy omarchy-aarch64/omarchy-settings omarchy-aarch64/omarchy-keyring omarchy-aarch64/ttf-jetbrains-mono-nerd-basic)
  local -A versions=() filenames=() architectures=()
  metadata=$(pacman -Spdd --print-format '%r %n %v %a %f' "${targets[@]}") ||
    fail "The ARM repository has no complete Omarchy release. Retry after a package release is published; no source build was attempted."
  while read -r repository package version architecture filename; do
    [[ $repository == "omarchy-aarch64" && ( $architecture == "aarch64" || $architecture == "any" ) ]] ||
      fail "Unexpected package source or architecture: $repository/$package ($architecture)."
    case $package in
      omarchy | omarchy-settings | omarchy-keyring | ttf-jetbrains-mono-nerd-basic) ;;
      *) fail "Unexpected package in release: $package" ;;
    esac
    [[ -n $version && -n $filename && $filename != */* && -z ${versions[$package]:-} ]] || fail "Invalid ARM package metadata for $package."
    versions[$package]=$version
    filenames[$package]=$filename
    architectures[$package]=$architecture
  done <<< "$metadata"
  (( ${#versions[@]} == 4 )) || fail "The ARM repository has no complete Omarchy release."
  selected_release=${versions[omarchy]}
  [[ $selected_release == "${versions[omarchy-settings]}" ]] ||
    fail "ARM package release mismatch: omarchy=$selected_release, omarchy-settings=${versions[omarchy-settings]}. Retry after publication completes."

  # Download without installing or resolving the desktop's dependencies yet.
  # Pacman validates the archives using the repository's configured policy.
  local prebuilt_cache
  prebuilt_cache=$(pacman-conf CacheDir | head -1) || fail "Cannot read pacman's package cache configuration."
  [[ $prebuilt_cache == /* ]] || fail "Pacman has no absolute package cache directory configured."
  sudo pacman -Swdd --noconfirm --cachedir "$prebuilt_cache" "${targets[@]}" ||
    fail "Could not download the selected ARM release $selected_release."
  local -a archives=()
  for package in omarchy omarchy-settings omarchy-keyring ttf-jetbrains-mono-nerd-basic; do
    archive="$prebuilt_cache/${filenames[$package]}"
    [[ -f $archive ]] || fail "Downloaded ARM release changed during installation; retry to select a complete release."
    info=$(bsdtar -xOf "$archive" .PKGINFO) || fail "Cannot read downloaded package: $package"
    grep -qxF "pkgname = $package" <<< "$info" &&
      grep -qxF "pkgver = ${versions[$package]}" <<< "$info" &&
      grep -qxF "arch = ${architectures[$package]}" <<< "$info" || fail "Downloaded package does not match selected release: $package"
    if [[ $package == "omarchy" ]]; then
      grep -qE '^depend = snapper([<>=].*)?$' <<< "$info" ||
        fail "ARM release $selected_release lacks the required Snapper dependency. A corrected package release must be published before installation."
      helper=$(bsdtar -xOf "$archive" usr/share/omarchy/install/helpers/mac-install.sh 2>/dev/null) ||
        fail "ARM release $selected_release lacks the packaged Mac installer. A compatible release must be published before installation."
      grep -qxF '# omarchy:mac-install-protocol=1' <<< "$helper" || fail "ARM release $selected_release uses an unsupported Mac installer protocol."
    elif [[ $package == "omarchy-settings" ]]; then
      settings_files=$(bsdtar -tf "$archive" | sed 's|^\./||') || fail "Cannot list settings payload."
      grep -qxF 'etc/mkinitcpio.conf.d/omarchy_hooks.conf' <<< "$settings_files" ||
        fail "ARM release $selected_release lacks the Apple Silicon boot configuration."
      if grep -qxF 'usr/share/omarchy/default/systemd/user/omarchy-brightness-keyboard-auto.service' <<< "$settings_files"; then
        grep -qxF 'usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service' <<< "$settings_files" ||
          fail "ARM release $selected_release lacks the required keyboard brightness service. A corrected package release must be published before installation."
      fi
    fi
    archives+=("$archive")
  done
  log "Installing published Omarchy ARM release $selected_release"
  # An existing source build may share this version but contain different
  # files. Install the validated archives even when the versions already match.
  sudo env OMARCHY_UPDATE_PACMAN=1 pacman -U --noconfirm "${archives[@]}"
}

# The Asahi Alarm image normally ships this keyring already. A generic
# aarch64 base does not, and pacman refuses to create the asahi-alarm database
# until its master key is trusted. Install the keyring before the first refresh
# so later AUR and ARM-repo package operations do not fail with a misleading
# "database does not exist" error.
ensure_asahi_alarm_keyring() {
  grep -q '^\[asahi-alarm\]' /etc/pacman.conf || return 0
  pacman -Q asahi-alarm-keyring >/dev/null 2>&1 && return 0

  if ! sudo pacman-key --list-keys "$asahi_alarm_key" >/dev/null 2>&1; then
    log "Importing the Asahi Alarm package signing key"
    sudo pacman-key --recv-keys "$asahi_alarm_key" --keyserver hkps://keyserver.ubuntu.com
  fi
  sudo pacman-key --lsign-key "$asahi_alarm_key" >/dev/null

  log "Installing the Asahi Alarm package keyring"
  sudo pacman -Sy --needed --noconfirm asahi-alarm-keyring
}

# Compared in bash rather than with grep against a process substitution, which
# ugrep answers differently from GNU grep.
# The shipped pacman.conf only lands during post-install, after the package set
# is already installed, so the repo has to be added now: otherwise herdr builds
# zig0.15 from source for two hours and aarch64 rejects it anyway.
ensure_arm_package_repo() {
  if ! grep -q '^\[omarchy-aarch64\]' /etc/pacman.conf; then
    local block
    block=$(sed -n '/^\[omarchy-aarch64\]/,/^Server[[:space:]]*=/p' \
      "$checkout/default/pacman/pacman-stable.conf")
    [[ -n $block ]] || fail "default/pacman/pacman-stable.conf has no [omarchy-aarch64] section."

    log "Adding the Omarchy ARM package repo"
    printf '\n%s\n' "$block" | sudo tee -a /etc/pacman.conf >/dev/null
  fi

  ensure_asahi_alarm_keyring
  omarchy_arm_prepare_package_sources
  local -a targets
  mapfile -t targets < <(omarchy_arm_package_upgrade_args)
  # The core release is selected and validated as a pair below. A generic
  # sysupgrade must not replace it before validation or during finalization.
  targets+=(--ignore omarchy,omarchy-settings,omarchy-keyring,ttf-jetbrains-mono-nerd-basic)
  log "Upgrading system packages and installing the compatible Hyprland stack"
  sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu --needed --noconfirm "${targets[@]}"
}

load_unavailable_packages() {
  local unavailable="$checkout/install/omarchy-aarch64-unavailable.packages" line

  unavailable_packages=()
  [[ -f $unavailable ]] || return 0

  while read -r line; do
    [[ -n $line ]] && unavailable_packages+=("$line")
  done < <(grep -vE '^[[:space:]]*(#|$)' "$unavailable")
}

confirm() {
  local question="$1"

  if command -v gum >/dev/null 2>&1; then
    # --default=false to match the [y/N] fallback below: gum selects Yes
    # otherwise, so Enter accepts -- and what this asks about is whether to
    # spend three hours building packages that were measured to fail.
    gum confirm --default=false "$question" </dev/tty
  else
    local answer
    read -r -p "$question [y/N] " answer </dev/tty
    [[ $answer == "y" || $answer == "Y" ]]
  fi
}

# Default to skipping, because building these was measured to fail. Offer the
# choice anyway: an AUR package can gain aarch64 support at any time, and a
# stale entry here should cost a prompt rather than be permanently wrong.
should_attempt_unavailable() {
  (( ${#unavailable_packages[@]} )) || return 1
  [[ ${OMARCHY_TRY_UNAVAILABLE:-0} == "1" ]] && return 0
  [[ -r /dev/tty ]] || return 1

  warn "No aarch64 build is known for: ${unavailable_packages[*]}"
  echo "Building them took about 3 hours on a clean install and still failed."
  echo "They may have gained ARM support since, so you can try."

  confirm "Try building them anyway?"
}

package_is_unavailable_here() {
  local package="$1" candidate

  for candidate in ${unavailable_packages[@]+"${unavailable_packages[@]}"}; do
    [[ $candidate == "$package" ]] && return 0
  done

  return 1
}

install_default_package_set() {
  local package skipped=() unbuildable=() attempt_unavailable=0

  load_unavailable_packages
  if should_attempt_unavailable; then
    attempt_unavailable=1
  fi

  log "Installing the default package set (AUR builds take a while)"
  while read -r package; do
    # Already installed in the full compatibility transaction. An unqualified
    # yay target would select the regular repository and can downgrade it.
    if omarchy_arm_package_is_selected "$package"; then
      pacman -Q "$package" >/dev/null || fail "Compatible package missing after system upgrade: $package"
      continue
    fi
    # These compile a dependency chain for hours before failing an architecture
    # check, so do not start them unless asked to.
    if (( ! attempt_unavailable )) && package_is_unavailable_here "$package"; then
      unbuildable+=("$package")
      continue
    fi
    yay -S --needed --noconfirm "$package" </dev/null || skipped+=("$package")
  done < <(grep -vE '^\s*(#|$)' "$checkout/install/omarchy-base.packages")

  if (( ${#unbuildable[@]} )); then
    warn "Not attempted, no known aarch64 build: ${unbuildable[*]}"
    echo "Try one later with: yay -S <package>"
  fi

  # Apple GPUs cannot run gpu-screen-recorder; recording falls back to this.
  yay -S --needed --noconfirm wf-recorder </dev/null || skipped+=("wf-recorder")

  if (( ${#skipped[@]} )); then
    warn "Skipped packages with no aarch64 build: ${skipped[*]}"
  fi
}

seed_user_defaults() {
  # useradd -m already ran for this user, so /etc/skel never seeded $HOME.
  # Replaying it is exactly what omarchy-reinstall-configs does.
  log "Seeding shipped defaults into $HOME"
  omarchy-reinstall-configs
}

run_system_setup() {
  log "Running Omarchy system setup"
  sudo omarchy-apply-system --install-user "$USER" --first-install

  # System setup restores pacman.conf and can introduce repositories absent
  # from the starting image. Trust their keys and refresh with a full upgrade
  # before user setup installs packages, retaining the explicit edge stack.
  ensure_arm_package_repo
  verify_installed_release "$selected_release"

  log "Running Omarchy user setup"
  omarchy-provision-user --first-install
}

# On a btrfs root (see omarchy-system-btrfs-migrate) record the finished
# install as the @factory baseline, mirroring the snapshot the Quattro ISO
# takes, so omarchy-system-factory-reset can return the machine to this state.
# The reset itself scrubs user accounts from the clone, so a baseline taken
# after user creation is fine. Silently does nothing on ext4 roots.
snapshot_factory_baseline() {
  [[ $(findmnt -no FSTYPE /) == btrfs ]] || return 0
  findmnt -no OPTIONS / | grep -q 'subvol=/@\(,\|$\)' || return 0

  local top=/run/omarchy-install-top device
  device=$(findmnt -no SOURCE / | sed 's/\[.*\]//')

  sudo mkdir -p "$top"
  sudo mount -o subvolid=5 "$device" "$top"
  if [[ ! -d $top/@factory ]]; then
    log "Snapshotting the installed system as the @factory reset baseline"
    sudo btrfs subvolume snapshot -r "$top/@" "$top/@factory" >/dev/null
  fi
  sudo umount "$top"
  sudo rmdir "$top"
}

# This entry point is shipped inside the omarchy package. Keep the protocol
# marker stable until the hand-off arguments change incompatibly.
# omarchy:mac-install-protocol=1
verify_installed_release() {
  local expected="$1" package installed
  for package in omarchy omarchy-settings; do
    installed=$(pacman -Q "$package") || fail "Installed package missing: $package"
    [[ $installed == "$package $expected" ]] || fail "Installed $package does not match selected release $expected: $installed"
  done
}

finish_install() {
  check_preconditions
  selected_release="$1"
  verify_installed_release "$selected_release"
  source "$checkout/default/bash/env-bootstrap"
  [[ $OMARCHY_PATH == "$checkout" ]] || fail "Disable the development link before installing a packaged release (omarchy dev unlink)."
  ensure_gum
  ensure_aur_helper
  install_default_package_set
  seed_user_defaults
  run_system_setup
  snapshot_factory_baseline
  log "Install complete. Reboot to start Omarchy."
}

main() {
  local from_source=0
  case ${1:-} in
    "") ;;
    --from-source) from_source=1; shift ;;
    --finish-install)
      (( $# == 2 )) || fail "Internal package hand-off requires a release."
      finish_install "$2"
      return
      ;;
    -h | --help)
      echo "Usage: bash install.sh [--from-source]"
      echo "Install published ARM packages; --from-source builds this checkout for development."
      return
      ;;
    *) fail "Unknown argument: $1" ;;
  esac
  (( $# == 0 )) || fail "Unexpected argument: $1"
  check_preconditions
  ensure_utf8_locale
  ensure_arm_package_repo
  ensure_gum
  if (( from_source )); then
    ensure_aur_helper
    ensure_package_sources
    build_omarchy_packages
    install_omarchy_packages
    selected_release=$(pacman -Q omarchy)
    selected_release=${selected_release#omarchy }
  else
    install_prebuilt_omarchy_packages
  fi
  # Continue with the setup code and package list shipped in that release,
  # including for source builds. The checkout is only the bootstrap now.
  exec bash /usr/share/omarchy/install/helpers/mac-install.sh --finish-install "$selected_release"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
