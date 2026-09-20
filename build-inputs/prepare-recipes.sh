#!/bin/bash

# The desktop owns the recipe revision and ARM overlay used by every builder.
# Copy before patching so a retry never changes the caller's checkout.
prepare_omarchy_recipes() {
  local recipe_source="$1" destination="$2" inputs_dir revision actual
  inputs_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  revision=$(<"$inputs_dir/omarchy-pkgs-revision")
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid package recipe pin' >&2; return 1; }
  [[ ! -d $recipe_source/pkgbuilds ]] || recipe_source="$recipe_source/pkgbuilds"

  actual=$(git -C "$recipe_source" rev-parse HEAD 2>/dev/null) || actual=unversioned
  if [[ ${OMARCHY_ALLOW_CUSTOM_RECIPES:-0} != 1 ]]; then
    [[ $actual == "$revision" ]] || {
      echo "Package recipes must be at $revision (found $actual). Set OMARCHY_ALLOW_CUSTOM_RECIPES=1 only for an intentional custom build." >&2
      return 1
    }
    [[ -z $(git -C "$recipe_source" status --porcelain --untracked-files=all -- .) ]] || {
      echo 'Package recipe checkout has local changes; use a clean checkout or explicitly opt into a custom build.' >&2
      return 1
    }
  else
    echo "Warning: custom recipes selected ($actual); this is not a release-qualified build." >&2
  fi
  [[ ! -e $destination ]] || { echo "Recipe output already exists: $destination" >&2; return 1; }
  mkdir -p "$destination/pkgbuilds" || return 1
  if [[ ${OMARCHY_ALLOW_CUSTOM_RECIPES:-0} == 1 ]]; then
    cp -a "$recipe_source/." "$destination/pkgbuilds/" || return 1
  else
    # Export the immutable tree; ignored makepkg cache/build files in a clean
    # developer checkout must never become implicit release inputs.
    git -C "$(git -C "$recipe_source" rev-parse --show-toplevel)" archive "$revision:pkgbuilds" | tar -xf - -C "$destination/pkgbuilds" || return 1
  fi
  local overlay="$inputs_dir/omarchy-first-run-packages.patch"
  if git apply --check --unsafe-paths --directory="$destination" "$overlay" 2>/dev/null; then
    git apply --unsafe-paths --directory="$destination" "$overlay" || return 1
  elif ! git apply --reverse --check --unsafe-paths --directory="$destination" "$overlay" 2>/dev/null; then
    echo 'Package recipes no longer match the ARM first-run overlay; review them before building.' >&2
    return 1
  fi
  cp -a "$inputs_dir/omarchy-mac-keyring" "$destination/pkgbuilds/" || return 1
  cp -a "$inputs_dir/../default/pacman/keyrings/omarchy-mac.gpg" \
    "$inputs_dir/../default/pacman/keyrings/omarchy-mac-trusted" \
    "$inputs_dir/../default/pacman/keyrings/omarchy-mac-revoked" \
    "$destination/pkgbuilds/omarchy-mac-keyring/" || return 1
  printf '%s\n' "recipe_commit=$actual" "recipe_pin=$revision" "custom_recipes=${OMARCHY_ALLOW_CUSTOM_RECIPES:-0}" >"$destination/provenance"
  (cd "$destination" && find pkgbuilds -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >>"$destination/provenance"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  prepare_omarchy_recipes "${1:?Usage: prepare-recipes.sh SOURCE DESTINATION}" "${2:?Destination required}"
fi
