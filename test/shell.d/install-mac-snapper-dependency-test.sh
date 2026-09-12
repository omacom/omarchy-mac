#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# Exercise the actual build path with a harmless makepkg substitute that
# evaluates dependencies from the patched PKGBUILD as makepkg would.
for dependency in absent snapper 'snapper>=0.12'; do
  case_dir="$work_dir/${dependency//[>=]/_}"
  mkdir -p "$case_dir/source/omarchy" "$case_dir/build" "$case_dir/output"
  cat >"$case_dir/source/omarchy/PKGBUILD" <<'PKGBUILD'
pkgrel=1
depends=(
  'gum'
  'limine'
  'limine-mkinitcpio-hook'
  'limine-snapper-sync'
)
optdepends=('snapper: optional snapshots')
PKGBUILD
  if [[ $dependency != "absent" ]]; then
    sed -i "/^depends=(/a\\  '$dependency' # Existing upstream requirement" "$case_dir/source/omarchy/PKGBUILD"
  fi
  cp "$case_dir/source/omarchy/PKGBUILD" "$case_dir/original"

  (
    export OMARCHY_PACKAGE_OUTPUT="$case_dir/output"
    unset OMARCHY_PKGREL
    source "$ROOT/build-packages.sh"
    makepkg() {
      source ./PKGBUILD
      printf '%s\n' "${depends[@]}" >omarchy.pkg.tar.zst
    }
    build_package omarchy "$case_dir/source" "$case_dir/build"
    cp "$case_dir/build/omarchy/PKGBUILD" "$case_dir/once"
    ensure_snapper_dependency "$case_dir/build/omarchy/PKGBUILD"
    cmp "$case_dir/once" "$case_dir/build/omarchy/PKGBUILD"
  )

  expected_dependency=$dependency
  [[ $dependency != "absent" ]] || expected_dependency=snapper
  expected=$(printf '%s\n' gum "$expected_dependency" | sort)
  actual=$(sort "$case_dir/output/omarchy.pkg.tar.zst")
  [[ $actual == "$expected" ]] ||
    fail "Mac build requires Snapper exactly once and preserves other dependencies ($dependency)" "$actual"
  cmp "$case_dir/original" "$case_dir/source/omarchy/PKGBUILD" ||
    fail "Mac build leaves the upstream source PKGBUILD untouched"
  pass "Mac build requires Snapper without Limine and remains idempotent ($dependency)"
done
