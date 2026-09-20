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
  'omarchy-mac-keyring'
)
RECIPE
  ensure_omarchy_mac_keyring_dependency "$work_dir/omarchy-PKGBUILD"
  ensure_omarchy_mac_keyring_dependency "$work_dir/omarchy-PKGBUILD"
  [[ $(grep -c "^[[:space:]]*'omarchy-mac-keyring>=20260914-2'$" "$work_dir/omarchy-PKGBUILD") == 1 ]]
  [[ " ${packages[*]} " == *' omarchy-mac-keyring '* ]]
  source "$work_dir/omarchy-PKGBUILD"
  [[ $(vercmp 20260913-1 "${depends[1]#*>=}") == -1 ]]
  [[ $(vercmp 20260914-2 "${depends[1]#*>=}") == 0 ]]
) || fail 'omarchy package depends exactly once on the fork keyring'
pass 'build includes the fork keyring and makes it an Omarchy dependency'

(
  source "$ROOT/build-packages.sh" || exit 1
  for requirement in \
    omarchy-mac-keyring \
    'omarchy-mac-keyring>=20260913-1' \
    'omarchy-mac-keyring>=20260915-1' \
    'omarchy-mac-keyring>20260913-1' \
    'omarchy-mac-keyring>20260915-1' \
    'omarchy-mac-keyring=20260914-2' \
    'omarchy-mac-keyring=20260915-1'; do
    printf "depends=(\n  'before' '%s' 'after' # preserved comment\n)\n" "$requirement" >"$work_dir/shared-line" || exit 1
    ensure_omarchy_mac_keyring_dependency "$work_dir/shared-line" || exit 1
    cp "$work_dir/shared-line" "$work_dir/once" || exit 1
    ensure_omarchy_mac_keyring_dependency "$work_dir/shared-line" || exit 1
    cmp "$work_dir/once" "$work_dir/shared-line" || exit 1
    source "$work_dir/shared-line" || exit 1
    [[ ${depends[0]} == before && ${depends[2]} == after && ${#depends[@]} == 3 ]] || exit 1
    expected='omarchy-mac-keyring>=20260914-2'
    case $requirement in
      'omarchy-mac-keyring>=20260915-1'|'omarchy-mac-keyring>20260915-1'|'omarchy-mac-keyring=20260914-2'|'omarchy-mac-keyring=20260915-1')
        expected=$requirement
        ;;
    esac
    [[ ${depends[1]} == "$expected" ]] || exit 1
    grep -qF '# preserved comment' "$work_dir/shared-line" || exit 1
  done
) || fail 'keyring transition must preserve adjacent dependencies and stronger existing bounds'
pass 'keyring dependency normalization preserves shared lines and stronger version requirements'

(
  source "$ROOT/build-packages.sh"
  for requirement in \
    'omarchy-mac-keyring=20260913-1' \
    'omarchy-mac-keyring<20260914-2' \
    'omarchy-mac-keyring<=20260914-2'; do
    printf "depends=(\n  '%s'\n)\n" "$requirement" >"$work_dir/rejected-keyring-bound"
    if ( ensure_omarchy_mac_keyring_dependency "$work_dir/rejected-keyring-bound" 2>/dev/null ); then
      exit 1
    fi
  done
) || fail 'stale exact pins and upper bounds must fail closed'
pass 'keyring dependency normalization rejects stale exact pins and upper bounds'

# Reject dirty/wrong default sources before touching an existing output.
(
  source "$ROOT/build-inputs/prepare-recipes.sh"
  mkdir "$work_dir/unknown"
  if prepare_omarchy_recipes "$work_dir/unknown" "$work_dir/rejected" 2>/dev/null; then exit 1; fi
  [[ ! -e $work_dir/rejected ]]
) || fail 'unversioned recipes require explicit custom-build opt-in'
pass 'release builds reject unversioned recipe inputs before staging'

(
  source "$ROOT/build-inputs/prepare-recipes.sh" || exit 1
  OMARCHY_ALLOW_CUSTOM_RECIPES=1 prepare_omarchy_recipes \
    "$recipe_source" "$work_dir/with-keyring" >/dev/null || exit 1
  keyring="$work_dir/with-keyring/pkgbuilds/omarchy-mac-keyring"
  [[ -f $keyring/PKGBUILD && -f $keyring/omarchy-mac-keyring.install ]] || exit 1
  cmp "$ROOT/default/pacman/keyrings/omarchy-mac.gpg" "$keyring/omarchy-mac.gpg" || exit 1
  cmp "$ROOT/default/pacman/keyrings/omarchy-mac-trusted" "$keyring/omarchy-mac-trusted" || exit 1
  [[ ! -s $keyring/omarchy-mac-revoked ]] || exit 1
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
