#!/bin/bash

# Runs check against small synthetic repositories so every assertion is shown
# to pass on a clean set and to fail on the fault it guards against.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CHECK=$HERE/../check

for tool in pacman repo-add bsdtar; do
  command -v "$tool" >/dev/null || { echo "check-test needs $tool" >&2; exit 2; }
done

scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/package-resolution-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
lists=$scratch/lists
mkdir -p "$lists"

pass() { printf 'ok - %s\n' "$1"; }
fail() {
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# package REPO NAME VERSION [depend=DEP] [provides=NAME] [conflict=NAME] [file=PATH]...
package() {
  local repo=$1 name=$2 version=$3 spec build
  shift 3
  build=$scratch/build/$name-$version
  mkdir -p "$build" "$scratch/repos/$repo"
  {
    printf 'pkgname = %s\npkgbase = %s\npkgver = %s\narch = aarch64\nsize = 0\n' "$name" "$name" "$version"
    for spec in "$@"; do
      case $spec in
        depend=*) printf 'depend = %s\n' "${spec#depend=}" ;;
        provides=*) printf 'provides = %s\n' "${spec#provides=}" ;;
        conflict=*) printf 'conflict = %s\n' "${spec#conflict=}" ;;
        file=*)
          mkdir -p "$build/$(dirname "${spec#file=}")"
          echo "$name" >"$build/${spec#file=}"
          ;;
      esac
    done
  } >"$build/.PKGINFO"
  (cd "$build" && shopt -s nullglob && bsdtar --zstd -cf "$scratch/repos/$repo/$name-$version-aarch64.pkg.tar.zst" .PKGINFO *)
  repo-add -q "$scratch/repos/$repo/$repo.db.tar.gz" "$scratch/repos/$repo/$name-$version-aarch64.pkg.tar.zst" >/dev/null
}

# Rewrites a database in the older layout Arch Linux ARM still serves: dependency
# fields move to a depends file stored ahead of each package's desc.
legacy_layout() {
  local db=$scratch/repos/$1/$1.db.tar.gz tree=$scratch/legacy-$1 entry
  mkdir -p "$tree"
  bsdtar -xf "$db" -C "$tree"
  for entry in "$tree"/*/; do
    awk -v depends="${entry}depends" '/^%[A-Z0-9]+%$/ { split_out = $0 ~ /^%(DEPENDS|PROVIDES|CONFLICTS|REPLACES|OPTDEPENDS)%$/ } { if (split_out) print > depends; else print }' \
      "${entry}desc" >"${entry}desc.new"
    mv "${entry}desc.new" "${entry}desc"
  done
  rm -f "$db"
  (cd "$tree" && for entry in */; do [[ ! -f ${entry}depends ]] || echo "${entry}depends"; echo "${entry}desc"; done | bsdtar -czf "$db" -T -)
}

# platform NAME "REPO..." "PACKAGE..." [VARIABLE=VALUE lines for the platform file]
platform() {
  local name=$1 repos=$2 wanted=$3 repo
  shift 3
  mkdir -p "$scratch/platforms/$name"
  printf '%s\n' $wanted >"$lists/$name.packages"
  {
    printf '[options]\nArchitecture = aarch64\n'
    for repo in $repos; do
      printf '\n[%s]\nServer = file://%s/repos/%s\n' "$repo" "$scratch" "$repo"
    done
  } >"$scratch/platforms/$name/pacman.conf"
  {
    printf 'lists=(%s)\n' "$lists/$name.packages"
    printf '%s\n' "$@"
  } >"$scratch/platforms/$name/platform"
}

run() {
  output=$("$CHECK" --platforms "$scratch/platforms" --work "$scratch/work" "$@" 2>&1) && status=0 || status=$?
}

expect_pass() {
  run "$1"
  (( status == 0 )) || fail "$2" "$output"
  [[ -z ${3:-} ]] || grep -Eq "$3" <<<"$output" || fail "$2: output matches $3" "$output"
  pass "$2"
}

expect_fail() {
  run "$1"
  (( status != 0 )) || fail "$2" "$output"
  grep -Eq "^FAIL  $3" <<<"$output" || fail "$2: reported as $3" "$output"
  pass "$2"
}

generic='forbidden_packages=("${mac_only[@]}")'

package core filesystem 1-1 file=etc/hostname
package core linux-aarch64 7.0-1 provides=linux depend=filesystem file=usr/lib/modules/7.0/vmlinuz
package core tool 1.0-1 depend=filesystem file=usr/bin/tool
package omarchy omarchy 1.0-1 depend=tool file=usr/bin/omarchy
package omarchy omarchy-settings 1.0-1 file=usr/share/omarchy/settings
package omarchy linux-aurora 7.1-1 provides=linux=7.1 provides=linux-asahi conflict=linux-asahi depend=filesystem file=usr/lib/modules/7.1-aurora/vmlinuz
package omarchy omarchy-mac 1.0-1 depend=omarchy file=usr/bin/omarchy-mac-setup
package leaky leaky 1.0-1 depend=omarchy-mac
package omarchy clash 1.0-1 file=usr/bin/omarchy
package asahi-alarm linux-asahi 7.1-1 provides=linux=7.1 file=usr/lib/modules/7.1-asahi/vmlinuz
package asahi-alarm uboot-asahi 2026.07-1 file=boot/u-boot.bin
package kernel-first linux-aurora 7.1-1 provides=linux=7.1 file=usr/lib/modules/7.1-aurora/vmlinuz
package conflicts rival 1.0-1 conflict=tool file=usr/bin/rival
package conflicts old-rival 1.0-1 'conflict=tool<1.0' file=usr/bin/old-rival
package conflicts newtool 2-1 provides=newtool=1 file=usr/bin/newtool
package conflicts rival2 1-1 'conflict=newtool<2' file=usr/bin/rival2
package broken broken 1.0-1 depend=nothing-provides-this
package stale stale 1.0-1 file=usr/bin/stale
cp "$scratch/repos/stale/stale.files.tar.gz" "$scratch/stale-1.files"
package stale stale 2.0-1 file=usr/bin/stale
cp "$scratch/stale-1.files" "$scratch/repos/stale/stale.files.tar.gz"
legacy_layout core

platform generic "core omarchy" "omarchy omarchy-settings tool" "$generic" 'transitions=(omarchy omarchy-settings)'
expect_pass generic "a generic set that stays generic passes" \
  'ok    generic: linux resolves to core/linux-aarch64'
grep -Fq 'note  generic: Mac-only omarchy/linux-aurora still provides linux' <<<"$output" ||
  fail "a Mac-only linux provider is reported while it is not selected" "$output"
pass "a Mac-only linux provider is reported while it is not selected"
grep -Fq 'ok    generic: omarchy 1.0-1: -Su keeps equal and newer installs; -S replaces both; -S --needed skips equal' <<<"$output" ||
  fail "equal-version and locally-newer transitions are checked" "$output"
pass "equal-version and locally-newer transitions are checked"

platform apple "asahi-alarm core omarchy" "omarchy omarchy-mac linux-aurora uboot-asahi" 'kernel=linux-aurora' \
  'transitions=(omarchy-mac linux-aurora uboot-asahi)'
expect_pass apple "the Apple set resolves with the Asahi repositories" \
  'ok    apple: linux resolves to asahi-alarm/linux-asahi'
grep -Fq 'note  apple: with linux-aurora installed, linux resolves to omarchy/linux-aurora' <<<"$output" ||
  fail "the linux provider is reported with the Apple kernel installed" "$output"
pass "the linux provider is reported with the Apple kernel installed"

platform leak "core omarchy leaky" "omarchy leaky" "$generic"
expect_fail leak "a Mac package in a generic closure fails" 'leak: forbidden packages in the closure: omarchy/omarchy-mac'
grep -Eq '^FAIL  leak: packages depend on Mac-only names' <<<"$output" ||
  fail "a generic package depending on a Mac package fails" "$output"
pass "a generic package depending on a Mac package fails"

platform owners "core omarchy" "omarchy clash" 'transitions=()'
expect_fail owners "two packages owning one file fails" 'owners: files owned by more than one package'
grep -Eq '/usr/bin/omarchy: (omarchy clash|clash omarchy)' <<<"$output" || fail "the shared path and both owners are named" "$output"
pass "the shared path and both owners are named"

platform kernel "kernel-first core" "tool" "$generic"
expect_fail kernel "a generic root that selects the Apple kernel for linux fails" 'kernel: linux resolves to Mac-only kernel-first/linux-aurora'

platform conflicting "core conflicts" "tool rival"
expect_fail conflicting "two conflicting packages in one closure fail" 'conflicting: conflicting packages in the closure'
grep -Fq 'rival conflicts with tool (tool)' <<<"$output" || fail "the conflicting pair is named" "$output"
pass "the conflicting pair is named"

platform provided "core conflicts" "newtool rival2"
expect_fail provided "a versioned conflict met by a provide of the same name fails" 'provided: conflicting packages in the closure'

platform versioned "core conflicts" "tool old-rival"
expect_pass versioned "a versioned conflict the closure does not meet passes" 'ok    versioned: no declared conflicts'

platform repos "asahi-alarm core" "tool" "forbidden_repos=('asahi*')"
expect_fail repos "an Asahi repository on a generic platform fails" 'repos: forbidden repositories configured: asahi-alarm'

platform missing "core" "tool ghost" 'unpublished=([ghost]="not published yet")' 'transitions=(ghost)'
expect_pass missing "an unpublished package with a reason is skipped" 'skip  missing: ghost transitions \(not published yet\)'

platform unknown "core" "tool ghost" 'transitions=(ghost)'
expect_fail unknown "an unknown package fails" 'unknown: ghost is in no configured repository'
grep -Fq 'FAIL  unknown: ghost does not resolve for transitions' <<<"$output" || fail "an unknown transition package fails" "$output"
pass "an unknown transition package fails"

platform unresolved "core broken" "tool" 'transitions=(broken)'
expect_fail unresolved "a transition package that does not resolve fails" 'unresolved: broken does not resolve for transitions'

platform snapshot "core stale" "tool stale"
expect_fail snapshot "a files database from another snapshot fails" 'snapshot: the files databases lack the closure versions of'
grep -Fq 'stale/stale 2.0-1' <<<"$output" || fail "the package without file metadata is named" "$output"
pass "the package without file metadata is named"
