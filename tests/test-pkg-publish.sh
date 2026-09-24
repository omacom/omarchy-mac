#!/bin/bash
# Checks how omarchy-pkg-publish-aarch64 reads its target out of the pacman
# config. Getting this wrong publishes to the wrong place, or names the
# database something pacman will not fetch. Needs no root and no network.

set -uo pipefail

TOOL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/omarchy-pkg-publish-aarch64"
CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/default/pacman/pacman-stable.conf"
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

not_in_subshell() {
  ! ( "$@" )
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
echo "=== migration keyring publication ordering ==="

# The migration code is shipped inside the omarchy archive.  Publishing that
# archive must be impossible unless the final repository database provides the
# minimum fork keyring version encoded in the archive metadata.
if command -v repo-add >/dev/null && command -v bsdtar >/dev/null && command -v vercmp >/dev/null; then
  make_package() {
    local package="$1" version="$2" dependency="${3:-}" directory

    directory="$WORK/$package"

    mkdir -p "$directory"
    {
      printf 'pkgname = %s\n' "$package"
      printf 'pkgbase = %s\n' "$package"
      printf 'pkgver = %s\n' "$version"
      printf 'pkgdesc = test package\narch = any\nbuilddate = 1\nsize = 1\n'
      [[ -z $dependency ]] || printf 'depend = %s\n' "$dependency"
    } >"$directory/.PKGINFO"
    bsdtar -czf "$WORK/$package-$version-any.pkg.tar.gz" -C "$directory" .PKGINFO
    printf '%s\n' "$WORK/$package-$version-any.pkg.tar.gz"
  }

  keyring=$(make_package omarchy-mac-keyring 20260914-2)
  omarchy=$(make_package omarchy 4.0.3 'omarchy-mac-keyring>=20260914-2')
  mkdir -p "$WORK/ordered"
  cp "$keyring" "$omarchy" "$WORK/ordered/"
  (cd "$WORK/ordered" && repo-add omarchy-aarch64.db.tar.zst ./*.pkg.tar.gz) >/dev/null 2>&1
  check "omarchy publishes when its required keyring is in the final database" \
    verify_omarchy_keyring_publication "$WORK/ordered/omarchy-aarch64.db.tar.zst" "$omarchy"

  stale_keyring=$(make_package stale-keyring 20260913-1)
  # Its archive name may differ, but metadata controls the database identity.
  mkdir -p "$WORK/stale"
  cp "$omarchy" "$WORK/stale/"
  mkdir -p "$WORK/stale-keyring-metadata"
  sed 's/pkgname = stale-keyring/pkgname = omarchy-mac-keyring/' "$WORK/stale-keyring/.PKGINFO" >"$WORK/stale-keyring-metadata/.PKGINFO"
  bsdtar -czf "$WORK/stale/omarchy-mac-keyring-20260913-1-any.pkg.tar.gz" -C "$WORK/stale-keyring-metadata" .PKGINFO
  (cd "$WORK/stale" && repo-add omarchy-aarch64.db.tar.zst ./*.pkg.tar.gz) >/dev/null 2>&1
  check "omarchy publication fails when the repository keyring is too old" \
    not_in_subshell verify_omarchy_keyring_publication "$WORK/stale/omarchy-aarch64.db.tar.zst" "$omarchy"

  unbounded=$(make_package unbounded-omarchy 4.0.3)
  mkdir -p "$WORK/unbounded-metadata"
  sed 's/pkgname = unbounded-omarchy/pkgname = omarchy/' "$WORK/unbounded-omarchy/.PKGINFO" >"$WORK/unbounded-metadata/.PKGINFO"
  bsdtar -czf "$WORK/unbounded-omarchy.pkg.tar.gz" -C "$WORK/unbounded-metadata" .PKGINFO
  check "omarchy publication fails without a minimum keyring dependency" \
    not_in_subshell verify_omarchy_keyring_publication "$WORK/ordered/omarchy-aarch64.db.tar.zst" "$WORK/unbounded-omarchy.pkg.tar.gz"
else
  echo "- skipped the publication-order checks (repo-add/bsdtar/vercmp not installed)"
fi

echo
echo "=== $pass checks passed, $failures failed ==="
(( failures == 0 ))
