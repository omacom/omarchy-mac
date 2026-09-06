# Resolve package recipes by their reviewed commit, never by a moving branch.

omarchy_package_recipe_commit() {
  local recipe_runtime_path="$1" commit
  commit=$(cat "$recipe_runtime_path/packaging/omarchy-pkgs.commit") || return 1
  if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: packaging/omarchy-pkgs.commit must contain one full Git commit ID." >&2
    return 1
  fi
  printf '%s\n' "$commit"
}

omarchy_package_recipe_source() {
  local recipe_runtime_path="$1" commit="$2" candidate cache

  # Explicit and existing developer checkouts are object sources only. Exporting
  # the pinned commit leaves their branch, index and local edits untouched.
  if [[ -n ${OMARCHY_PKGS_PATH:-} ]]; then
    candidate=$OMARCHY_PKGS_PATH
    if ! git -C "$candidate" cat-file -e "$commit^{commit}" 2>/dev/null; then
      echo "Error: $candidate does not contain the pinned recipe commit $commit." >&2
      return 1
    fi
    git -C "$candidate" rev-parse --absolute-git-dir
    return 0
  fi

  for candidate in "$recipe_runtime_path/../omarchy-pkgs" "$HOME/code/omarchy-pkgs" \
    "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-build/omarchy-pkgs"; do
    if git -C "$candidate" cat-file -e "$commit^{commit}" 2>/dev/null; then
      git -C "$candidate" rev-parse --absolute-git-dir
      return 0
    fi
  done

  cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-build/recipes.git"
  if [[ ! -d $cache ]]; then
    mkdir -p "$(dirname "$cache")" || return 1
    git init --bare "$cache" >/dev/null || return 1
  fi
  if ! git -C "$cache" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$cache" fetch --depth 1 https://github.com/omacom/omarchy-pkgs.git "$commit" >&2 || return 1
  fi
  printf '%s\n' "$cache"
}

omarchy_package_recipe_export() {
  local recipe_runtime_path="$1" source="$2" destination="$3" commit="$4"
  local patch="$recipe_runtime_path/packaging/mac-profile.patch"

  mkdir -p "$destination" || return 1
  if ! (set -o pipefail; git -C "$source" archive "$commit" pkgbuilds/omarchy pkgbuilds/omarchy-settings \
    pkgbuilds/omarchy-keyring pkgbuilds/ttf-jetbrains-mono-nerd-basic |
    tar -xf - -C "$destination"); then
    echo "Error: could not export the pinned package recipes." >&2
    return 1
  fi
  # A caller may keep TMPDIR inside another Git checkout. Do not let Git use
  # that parent repository and silently filter our patch by its subdirectory.
  if ! GIT_CEILING_DIRECTORIES="$destination" git -C "$destination" apply --check "$patch" ||
    ! GIT_CEILING_DIRECTORIES="$destination" git -C "$destination" apply "$patch"; then
    echo "Error: the Mac package profile does not apply to the pinned recipes." >&2
    return 1
  fi
}
