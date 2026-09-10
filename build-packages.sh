#!/bin/bash

# Build the Omarchy packages for Apple Silicon from this checkout.
#
# omarchy, omarchy-settings, omarchy-keyring, and ttf-jetbrains-mono-nerd-basic
# are all arch=any, so they need no architecture-specific build. The only Apple
# Silicon delta is the limine bootloader stack, patched out below.
#
# OMARCHY_PKGREL bumps pkgrel on omarchy and omarchy-settings only, so a Mac
# hotfix can ship as 4.0.1-2 without waiting for an upstream 4.0.2 tag. Leave
# it unset to keep the PKGBUILD values.

set -euo pipefail

readonly checkout="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly output_dir="${OMARCHY_PACKAGE_OUTPUT:-$checkout/build-output}"
readonly source_cache="${OMARCHY_PACKAGE_SRCDEST:-${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-build/sources}"

# Macs boot m1n1 -> u-boot -> GRUB, so limine is wrong here. Two of these have
# no aarch64 build at all, and installing limine itself would make
# install/login/alt-bootloaders.sh skip the GRUB plymouth setup it guards.
readonly limine_dependencies=(
  limine
  limine-mkinitcpio-hook
  limine-snapper-sync
)

readonly packages=(
  omarchy-keyring
  ttf-jetbrains-mono-nerd-basic
  omarchy-settings
  omarchy
)

log() {
  printf '\033[32m==>\033[0m %s\n' "$*"
}

fail() {
  printf '\033[31mError:\033[0m %s\n' "$*" >&2
  exit 1
}

remove_build_dir() {
  [[ -n ${build_dir:-} ]] || return 0
  rm -rf "$build_dir"
}

find_omarchy_pkgs() {
  local candidate
  for candidate in \
    "${OMARCHY_PKGS_PATH:-}/pkgbuilds" \
    "${OMARCHY_PKGS_PATH:-}" \
    "$checkout/../omarchy-pkgs/pkgbuilds" \
    "$HOME/code/omarchy-pkgs/pkgbuilds" \
    "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-build/omarchy-pkgs/pkgbuilds"; do
    [[ -n $candidate && -d $candidate ]] || continue
    (cd -- "$candidate" && pwd)
    return 0
  done
  return 1
}

set_pkgrel() {
  local pkgbuild="$1" rel=${OMARCHY_PKGREL:-}

  # Mac hotfixes repackage the same upstream pkgver between tags, so they bump
  # pkgrel rather than pkgver to stay upgradeable without stealing the next
  # upstream tag. Unset OMARCHY_PKGREL to keep the PKGBUILD values.
  [[ -n $rel ]] || return 0
  [[ $rel =~ ^[1-9][0-9]*$ ]] || fail "OMARCHY_PKGREL must be a positive whole number, got: $rel"
  grep -qE '^pkgrel=' "$pkgbuild" || fail "no pkgrel= in $pkgbuild"
  sed -i "s/^pkgrel=.*/pkgrel=$rel/" "$pkgbuild"
  grep -qx "pkgrel=$rel" "$pkgbuild" || fail "could not set pkgrel=$rel in $pkgbuild"
}

# Drop the limine entries from depends=() without forking the PKGBUILD, so it
# keeps tracking upstream and only this delta is ours.
strip_limine_dependencies() {
  local pkgbuild="$1" dependency

  for dependency in "${limine_dependencies[@]}"; do
    sed -i "/^[[:space:]]*'${dependency}'[[:space:]]*$/d" "$pkgbuild"
  done

  for dependency in "${limine_dependencies[@]}"; do
    if grep -qE "^[[:space:]]*'${dependency}'[[:space:]]*$" "$pkgbuild"; then
      fail "could not remove '$dependency' from $pkgbuild"
    fi
  done
}

# Limine's snapshot integration normally pulls in Snapper transitively. Macs
# still need Snapper for btrfs setup and snapshots after dropping that stack,
# so make it a hard dependency rather than a best-effort default package.
ensure_snapper_dependency() {
  local pkgbuild="$1"

  grep -qx 'depends=(' "$pkgbuild" ||
    fail "omarchy PKGBUILD no longer has the expected depends array: $pkgbuild"
  if ! sed -n '/^depends=(/,/^)/p' "$pkgbuild" |
    grep -qE "^[[:space:]]*['\"]snapper([<>=][^'\"]*)?['\"]([[:space:]]|$)"; then
    sed -i "/^depends=(/a\\  'snapper'" "$pkgbuild"
  fi
}

# Upstream's package() deletes /etc/mkinitcpio.conf.d wholesale on aarch64,
# reasoning that omarchy_hooks.conf is the x86 file that would inject the
# Limine hooks into an Asahi initramfs. That is true of upstream's copy and
# false of ours: this fork rewrote the same file to insert the asahi hook --
# which stages the Apple Silicon display, Wi-Fi and neural-engine firmware
# into early boot -- and to drop btrfs-overlayfs when limine-snapper-sync is
# absent. Ship without it and the next mkinitcpio writes an image that cannot
# drive the hardware: the boot wedges in the initramfs, keyboard and all, with
# `avd: failed to load firmware` and apple-dcp errors as the only clue.
#
# Narrow the deletion to the Limine entry-tool config, which really is x86
# only, rather than forking the PKGBUILD, so it keeps tracking upstream.
keep_apple_silicon_mkinitcpio_drop_ins() {
  local pkgbuild="$1"
  local upstream_line='rm -rf "$pkgdir/etc/limine-entry-tool.d" "$pkgdir/etc/mkinitcpio.conf.d"'

  # Fail loudly if upstream restructures this. Silently not matching would
  # ship a package missing the asahi hook, which is the failure this exists
  # to prevent and the one nobody notices until the next kernel update.
  grep -qF "$upstream_line" "$pkgbuild" ||
    fail "omarchy-settings PKGBUILD no longer deletes /etc/mkinitcpio.conf.d as expected; re-check it against $pkgbuild"

  sed -i 's| "\$pkgdir/etc/mkinitcpio\.conf\.d"||' "$pkgbuild"

  ! grep -q 'pkgdir/etc/mkinitcpio\.conf\.d' "$pkgbuild" ||
    fail "could not keep /etc/mkinitcpio.conf.d in $pkgbuild"
  grep -qF 'rm -rf "$pkgdir/etc/limine-entry-tool.d"' "$pkgbuild" ||
    fail "lost the limine-entry-tool.d cleanup in $pkgbuild"
}

# makepkg runs with --nodeps because the runtime dependencies include packages
# built here, so pacman cannot resolve them yet. That skips makedepends too,
# leaving the build tools to be installed up front.
install_build_dependencies() {
  local pkgbuild_source="$1" package
  local -a build_dependencies=()

  for package in "${packages[@]}"; do
    while read -r dependency; do
      [[ -n $dependency ]] || continue
      build_dependencies+=("$dependency")
    done < <(sed -n '/^makedepends=(/,/^)/p' "$pkgbuild_source/$package/PKGBUILD" |
      sed '1d;$d' | tr -d "'\"" | tr -d ' ')
  done

  (( ${#build_dependencies[@]} )) || return 0

  # pacman -T reports only what is missing, so an already-equipped machine
  # needs no sudo at all, and repeated makedepends collapse.
  local -a missing=()
  mapfile -t missing < <(pacman -T "${build_dependencies[@]}" || true)
  (( ${#missing[@]} )) || return 0

  log "Installing build dependencies: ${missing[*]}"
  sudo pacman -S --needed --noconfirm "${missing[@]}"
}

remove_old_packages() {
  local artifact

  # This directory is the installer hand-off, not a package cache. A retry
  # after PKGBUILDs changed must not mix the previous build with this one.
  for artifact in "$output_dir"/*.pkg.tar.*; do
    [[ -f $artifact ]] || continue
    rm -f -- "$artifact"
  done
}

build_package() {
  local package="$1" pkgbuild_source="$2" build_dir="$3"
  local artifact
  local -a built=()

  log "Building $package"
  rm -rf "$build_dir/$package"
  cp -r "$pkgbuild_source/$package" "$build_dir/$package"

  if [[ $package == "omarchy" ]]; then
    strip_limine_dependencies "$build_dir/$package/PKGBUILD"
    ensure_snapper_dependency "$build_dir/$package/PKGBUILD"
  fi
  if [[ $package == "omarchy-settings" ]]; then
    keep_apple_silicon_mkinitcpio_drop_ins "$build_dir/$package/PKGBUILD"
  fi
  if [[ $package == "omarchy" || $package == "omarchy-settings" ]]; then
    set_pkgrel "$build_dir/$package/PKGBUILD"
  fi

  # SRCDEST caches downloaded sources outside the throwaway build directory, so
  # a rebuild does not re-fetch the 125 MB font archive.
  (
    cd "$build_dir/$package"
    SRCDEST="$source_cache" OMARCHY_SRC="$checkout" \
      makepkg --force --noconfirm --nodeps --skipinteg
  )

  # A configured makepkg signer leaves detached .sig files beside the archive;
  # pacman -U accepts package archives, not those signatures.
  for artifact in "$build_dir/$package"/*.pkg.tar.*; do
    [[ -f $artifact && $artifact != *.sig ]] || continue
    built+=("$artifact")
  done
  (( ${#built[@]} )) || fail "$package produced no package archive"
  mv -- "${built[@]}" "$output_dir/"
}

main() {
  [[ $(uname -m) == "aarch64" ]] || fail "This builds the Apple Silicon packages; run it on aarch64."
  command -v makepkg >/dev/null || fail "makepkg is required (install base-devel)."
  (( EUID != 0 )) || fail "Run this as your regular user, not as root."

  local pkgbuild_source package
  pkgbuild_source="$(find_omarchy_pkgs)" ||
    fail "No omarchy-pkgs checkout found. Set OMARCHY_PKGS_PATH or clone it beside this repo."
  log "Using PKGBUILDs from $pkgbuild_source"

  for package in "${packages[@]}"; do
    [[ -d "$pkgbuild_source/$package" ]] || fail "$pkgbuild_source/$package is missing."
  done

  install_build_dependencies "$pkgbuild_source"

  # build_dir stays global: an EXIT trap runs after main's locals are gone, and
  # under set -u a local would abort the trap instead of cleaning up.
  build_dir="$(mktemp -d)"
  trap remove_build_dir EXIT

  mkdir -p "$output_dir" "$source_cache"
  remove_old_packages
  for package in "${packages[@]}"; do
    build_package "$package" "$pkgbuild_source" "$build_dir"
  done

  log "Built packages in $output_dir"
  ls -1 "$output_dir"/*.pkg.tar.*
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
