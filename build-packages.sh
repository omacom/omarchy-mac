#!/bin/bash

# Build the Omarchy packages for Apple Silicon from this checkout.
#
# Recipes come from the commit in packaging/omarchy-pkgs.commit. The reviewed
# Mac profile preserves the fork's boot, memory and package-owned service
# configuration without copying the upstream PKGBUILDs into this repository.
# By default a build only checks dependencies. The installer explicitly sets
# OMARCHY_BUILD_DEPS=install when it should install missing build tools.
#
# OMARCHY_PKGREL bumps pkgrel on omarchy and omarchy-settings only, so a Mac
# hotfix can ship as 4.0.1-2 without waiting for an upstream 4.0.2 tag. Leave
# it unset to keep the PKGBUILD values.

set -euo pipefail

readonly checkout="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly output_dir="${OMARCHY_PACKAGE_OUTPUT:-$checkout/build-output}"
readonly source_cache="${OMARCHY_PACKAGE_SRCDEST:-${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-build/sources}"
source "$checkout/install/helpers/package-recipes.sh"

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

# makepkg runs with --nodeps because the runtime dependencies include packages
# built here, so pacman cannot resolve them yet. That skips makedepends too,
# leaving the build tools to be installed up front.
install_build_dependencies() {
  local pkgbuild_source="$1" package metadata field value mode=${OMARCHY_BUILD_DEPS:-check}
  local -a build_dependencies=()

  [[ $mode == "check" || $mode == "install" ]] || fail "OMARCHY_BUILD_DEPS must be check or install."
  for package in "${packages[@]}"; do
    metadata=$(cd "$pkgbuild_source/$package" && OMARCHY_SRC="$checkout" makepkg --printsrcinfo) ||
      fail "Could not read build dependencies for $package."
    while read -r field _ value; do
      if [[ $field == "makedepends" || $field == "makedepends_aarch64" ]]; then
        [[ -n $value ]] && build_dependencies+=("$value")
      fi
    done <<<"$metadata"
  done

  (( ${#build_dependencies[@]} )) || return 0

  # pacman -T reports only what is missing, so an already-equipped machine
  # needs no sudo at all, and repeated makedepends collapse.
  local -a missing=()
  local dependency_status=0 missing_output
  missing_output=$(pacman -T "${build_dependencies[@]}") || dependency_status=$?
  if (( dependency_status != 0 && dependency_status != 127 )); then
    fail "Could not check installed build dependencies (pacman exited $dependency_status)."
  fi
  if (( dependency_status == 127 )) && [[ -z $missing_output ]]; then
    fail "pacman reported missing dependencies without naming them."
  fi
  if [[ -n $missing_output ]]; then
    mapfile -t missing <<<"$missing_output"
  fi
  (( ${#missing[@]} )) || return 0

  if [[ $mode == "check" ]]; then
    fail "Missing build dependencies: ${missing[*]}. Install them first, or use OMARCHY_BUILD_DEPS=install."
  fi
  log "Installing build dependencies: ${missing[*]}"
  sudo pacman -S --needed --noconfirm "${missing[@]}"
}

remove_old_packages() {
  local artifact

  # This directory is the installer hand-off, not a package cache. A retry
  # after PKGBUILDs changed must not mix the previous build with this one.
  rm -f -- "$output_dir/build-provenance.txt"
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

  if [[ $package == "omarchy" || $package == "omarchy-settings" ]]; then
    set_pkgrel "$build_dir/$package/PKGBUILD"
  fi

  # SRCDEST caches downloaded sources outside the throwaway build directory, so
  # a rebuild does not re-fetch the 125 MB font archive.
  (
    cd "$build_dir/$package"
    SRCDEST="$source_cache" OMARCHY_SRC="$checkout" \
      makepkg --force --noconfirm --nodeps
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

write_build_provenance() {
  local recipe_commit="$1" runtime_commit runtime_state artifact metadata package_name package_version
  local -A package_versions=()
  runtime_commit=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || printf unknown)
  runtime_state=clean
  [[ -z $(git -C "$checkout" status --porcelain 2>/dev/null) ]] || runtime_state=modified
  {
    printf 'runtime_commit=%s\nruntime_state=%s\n' "$runtime_commit" "$runtime_state"
    printf 'runtime_version=%s\n' "$(cat "$checkout/version")"
    printf 'recipe_repository=https://github.com/omacom/omarchy-pkgs.git\nrecipe_commit=%s\n' "$recipe_commit"
    printf 'profile_sha256=%s\n' "$(sha256sum "$checkout/packaging/mac-profile.patch" | cut -d' ' -f1)"
    printf 'architecture=%s\n' "$(uname -m)"
    for artifact in "$output_dir"/*.pkg.tar.*; do
      [[ -f $artifact && $artifact != *.sig ]] || continue
      metadata=$(bsdtar -xOf "$artifact" .PKGINFO) || fail "Could not read package metadata from $artifact."
      package_name=$(awk '$1 == "pkgname" {print $3}' <<<"$metadata")
      package_version=$(awk '$1 == "pkgver" {print $3}' <<<"$metadata")
      [[ -n $package_name && -n $package_version ]] || fail "Incomplete package metadata in $artifact."
      package_versions[$package_name]=$package_version
      printf 'package=%s %s %s\n' "$package_name" "$package_version" "$(basename "$artifact")"
      printf 'artifact_sha256=%s %s\n' "$(sha256sum "$artifact" | cut -d' ' -f1)" "$(basename "$artifact")"
    done
    [[ -n ${package_versions[omarchy]:-} && ${package_versions[omarchy]} == "${package_versions[omarchy-settings]:-}" ]] ||
      fail "The runtime and settings archives must have matching package versions and releases."
  } >"$output_dir/build-provenance.txt"
}

main() {
  "$checkout/bin/omarchy-hw-aarch64" || fail "This builds the Apple Silicon packages; run it on aarch64."
  command -v makepkg >/dev/null || fail "makepkg is required (install base-devel)."
  command -v pacman >/dev/null || fail "pacman is required to check build dependencies."
  (( EUID != 0 )) || fail "Run this as your regular user, not as root."

  local pkgbuild_source package recipe_commit recipe_source
  recipe_commit=$(omarchy_package_recipe_commit "$checkout") || exit 1
  recipe_source=$(omarchy_package_recipe_source "$checkout" "$recipe_commit") || exit 1

  # build_dir stays global: an EXIT trap runs after main's locals are gone.
  build_dir="$(mktemp -d)"
  trap remove_build_dir EXIT
  omarchy_package_recipe_export "$checkout" "$recipe_source" "$build_dir/recipes" "$recipe_commit" || exit 1
  pkgbuild_source="$build_dir/recipes/pkgbuilds"
  log "Using package recipes at $recipe_commit with the reviewed Mac profile"

  for package in "${packages[@]}"; do
    [[ -d "$pkgbuild_source/$package" ]] || fail "$pkgbuild_source/$package is missing."
  done

  install_build_dependencies "$pkgbuild_source"

  mkdir -p "$output_dir" "$source_cache"
  remove_old_packages
  for package in "${packages[@]}"; do
    build_package "$package" "$pkgbuild_source" "$build_dir"
  done
  write_build_provenance "$recipe_commit"

  log "Built packages in $output_dir"
  ls -1 "$output_dir"/*.pkg.tar.*
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
