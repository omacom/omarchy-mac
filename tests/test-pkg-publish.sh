#!/bin/bash
# Checks how omarchy-pkg-publish-aarch64 reads its target out of the pacman
# config. Getting this wrong publishes to the wrong place, or names the
# database something pacman will not fetch. Needs no root and no network.

set -uo pipefail

TOOL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/omarchy-pkg-publish-aarch64"
CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/default/pacman/aarch64/pacman-stable.conf"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0
failures=0

# shellcheck source=/dev/null
source "$TOOL"
set +e # the script sets -e for its own run

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "✓ $label"
    ((++pass))
  else
    echo "✗ $label"
    ((++failures))
  fi
}

not() {
  ! "$@"
}

echo "=== reading the release out of a Server line ==="

check "owner, repo and tag come back" \
  [ "$(parse_repo_server https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge)" \
    = "omarchy-mac/omarchy-pkgs-aarch64 edge" ]

check "a different owner and tag work too" \
  [ "$(parse_repo_server https://github.com/malik-na/pkgs/releases/download/v1.2)" \
    = "malik-na/pkgs v1.2" ]

check "a non-GitHub server is refused" \
  not parse_repo_server https://example.com/arch/aarch64

check "a GitHub URL that is not a release is refused" \
  not parse_repo_server https://github.com/omarchy-mac/omarchy-pkgs-aarch64

check "a missing tag is refused" \
  not parse_repo_server https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/

check "a tag with a slash is refused" \
  not parse_repo_server https://github.com/o/r/releases/download/edge/extra

echo
echo "=== reading the repo's own pacman config ==="

# The names here are what pacman fetches: get them wrong and every machine
# silently keeps building from source.
check "the section name is found" \
  [ "$(repo_name_from_conf "$CONF")" = "omarchy-aarch64" ]

check "the Server line is found" \
  [ -n "$(server_url_from_conf "$CONF")" ]

check "the shipped config parses into a real target" \
  [ -n "$(parse_repo_server "$(server_url_from_conf "$CONF")")" ]

echo
echo "=== a config with the section but no Server ==="

printf '[omarchy-aarch64]\nSigLevel = Optional TrustAll\n' >"$WORK/no-server.conf"
check "no Server means no target" \
  [ -z "$(server_url_from_conf "$WORK/no-server.conf")" ]

printf '[other]\nServer = https://github.com/o/r/releases/download/edge\n' >"$WORK/other.conf"
check "another section's Server is not picked up" \
  [ -z "$(server_url_from_conf "$WORK/other.conf")" ]

echo
echo "=== an epoch package is staged under the name GitHub serves ==="

# GitHub allows no colon in a release asset name and rewrites it to a dot
# without saying so. If the database keeps the colon, every pacman install of
# that package 404s -- which is how brave-origin-bin-1:1.93.136 first went out.
check "a colon becomes a dot" \
  [ "$(github_asset_name brave-origin-bin-1:1.93.136-1-aarch64.pkg.tar.xz)" \
    = "brave-origin-bin-1.1.93.136-1-aarch64.pkg.tar.xz" ]

check "a name without a colon is untouched" \
  [ "$(github_asset_name localsend-1.18.1-2-aarch64.pkg.tar.xz)" \
    = "localsend-1.18.1-2-aarch64.pkg.tar.xz" ]

check "every package is staged through the rename, not copied verbatim" \
  grep -q 'cp "$pkg" "$db_dir/$(github_asset_name' "$TOOL"

check "no bulk copy that would bypass it" \
  not grep -qF 'cp "${built[@]}"' "$TOOL"

# Prove the renamed file still describes itself correctly: pacman resolves
# versions from the database's VERSION field, which repo-add reads out of the
# package's own .PKGINFO, while FILENAME is what it fetches.
if command -v repo-add >/dev/null && command -v bsdtar >/dev/null; then
  (
    cd "$WORK"
    printf 'pkgname = fakepkg\npkgbase = fakepkg\npkgver = 1:2.0-1\npkgdesc = t\narch = any\nbuilddate = 1\nsize = 1\n' >.PKGINFO
    bsdtar -czf "$(github_asset_name 'fakepkg-1:2.0-1-any.pkg.tar.gz')" .PKGINFO
    repo-add --new testrepo.db.tar.zst ./fakepkg-*.pkg.tar.gz
  ) >/dev/null 2>&1
  desc=$(tar -xOf "$WORK/testrepo.db.tar.zst" --wildcards '*/desc' 2>/dev/null)

  check "the database names a file GitHub can serve" \
    [ "$(grep -A1 '%FILENAME%' <<<"$desc" | tail -1)" = "fakepkg-1.2.0-1-any.pkg.tar.gz" ]

  check "the epoch survives in the version pacman compares" \
    [ "$(grep -A1 '%VERSION%' <<<"$desc" | tail -1)" = "1:2.0-1" ]
else
  echo "- skipped the repo-add checks (repo-add/bsdtar not installed)"
fi

echo
echo "=== $pass checks passed, $failures failed ==="
(( failures == 0 ))
