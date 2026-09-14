#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
recipe_source="${OMARCHY_PKGS_PATH:-$ROOT/../omarchy-pkgs}"
[[ ! -d $recipe_source/pkgbuilds ]] || recipe_source="$recipe_source/pkgbuilds"

# Exercise local-source package metadata, including the pair's dynamic pin.
cat >"$work_dir/PKGBUILD" <<'RECIPE'
pkgver=99.0.0
pkgrel=9
depends=("omarchy-settings=${pkgver}")
RECIPE
(
  source "$ROOT/build-packages.sh"
  set_source_version "$work_dir/PKGBUILD"
  source "$work_dir/PKGBUILD"
  [[ $pkgver == "$(<"$ROOT/version")" && $pkgrel == 1 ]]
  [[ ${depends[0]} == "omarchy-settings=$(<"$ROOT/version")" ]]
  OMARCHY_PKGREL=3 set_pkgrel "$work_dir/PKGBUILD"
  OMARCHY_PKGREL=3 set_source_version "$work_dir/PKGBUILD"
  source "$work_dir/PKGBUILD"
  [[ $pkgrel == 3 ]]
) || fail 'local source version controls package metadata and exact pair dependency'
pass 'source version replaces stale recipe version and preserves explicit pkgrel'

(
  source "$ROOT/build-packages.sh"
  cat >"$work_dir/omarchy-PKGBUILD" <<'RECIPE'
depends=(
  'omarchy-settings'
)
RECIPE
  ensure_omarchy_mac_keyring_dependency "$work_dir/omarchy-PKGBUILD"
  ensure_omarchy_mac_keyring_dependency "$work_dir/omarchy-PKGBUILD"
  [[ $(grep -c "^[[:space:]]*'omarchy-mac-keyring'$" "$work_dir/omarchy-PKGBUILD") == 1 ]]
  [[ " ${packages[*]} " == *' omarchy-mac-keyring '* ]]
) || fail 'omarchy package depends exactly once on the fork keyring'
pass 'build includes the fork keyring and makes it an Omarchy dependency'

# Reject dirty/wrong default sources before touching an existing output.
(
  source "$ROOT/build-inputs/prepare-recipes.sh"
  mkdir "$work_dir/unknown"
  if prepare_omarchy_recipes "$work_dir/unknown" "$work_dir/rejected" 2>/dev/null; then exit 1; fi
  [[ ! -e $work_dir/rejected ]]
) || fail 'unversioned recipes require explicit custom-build opt-in'
pass 'release builds reject unversioned recipe inputs before staging'

(
  source "$ROOT/build-inputs/prepare-recipes.sh"
  OMARCHY_ALLOW_CUSTOM_RECIPES=1 prepare_omarchy_recipes \
    "$recipe_source" "$work_dir/with-keyring" >/dev/null
  keyring="$work_dir/with-keyring/pkgbuilds/omarchy-mac-keyring"
  [[ -f $keyring/PKGBUILD && -f $keyring/omarchy-mac-keyring.install ]]
  cmp "$ROOT/default/pacman/keyrings/omarchy-mac.gpg" "$keyring/omarchy-mac.gpg"
  cmp "$ROOT/default/pacman/keyrings/omarchy-mac-trusted" "$keyring/omarchy-mac-trusted"
  [[ ! -s $keyring/omarchy-mac-revoked ]]
) || fail 'prepared recipes contain the exact pinned fork keyring payload'
pass 'prepared recipes carry exact fork-owned trust bytes'

# The fork keyring is injected locally and deliberately absent from the pinned
# upstream recipe checkout. Validate only after preparing the combined tree.
(
  source "$ROOT/build-packages.sh"
  upstream="$recipe_source"
  prepared="$work_dir/prepared-with-fork-keyring"
  [[ ! -e $upstream/omarchy-mac-keyring ]]
  if ( require_package_recipes "$upstream" >/dev/null 2>&1 ); then exit 1; fi

  OMARCHY_ALLOW_CUSTOM_RECIPES=1 prepare_omarchy_recipes "$upstream" "$prepared" >/dev/null
  require_package_recipes "$prepared/pkgbuilds"
) || fail 'package validation must run against locally augmented recipes'
pass 'local keyring recipe is accepted after recipe preparation'

# Check Arch's interpreted metadata, not grep of PKGBUILD shell syntax.
# The fixtures cover both common and architecture-specific build dependencies.
(
  source "$ROOT/build-packages.sh"
  makepkg() { printf '\tmakedepends = git\n\tmakedepends_aarch64 = imagemagick>=7\n\tmakedepends_x86_64 = wrong-arch\n'; }
  uname() { echo aarch64; }
  pacman() {
    [[ $1 == -T ]]
    [[ $* == *'imagemagick>=7'* && $* != *wrong-arch* ]]
    return 0
  }
  for package in "${packages[@]}"; do mkdir -p "$work_dir/recipes/$package"; done
  install_build_dependencies "$work_dir/recipes"
  pacman() { return 1; }
  if ( install_build_dependencies "$work_dir/recipes" >/dev/null 2>&1 ); then exit 1; fi
) || fail 'build dependency resolution honors arch arrays and rejects database errors'
pass 'build dependencies use makepkg metadata and propagate database errors'
