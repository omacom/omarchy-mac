#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command git
require_command tar
pkgs_root="${OMARCHY_PKGS_PATH:-$ROOT/../omarchy-pkgs}"
[[ ! -d $pkgs_root/pkgbuilds ]] || pkgs_root="$pkgs_root/pkgbuilds"
[[ -f $pkgs_root/omarchy-settings/PKGBUILD ]] || fail 'omarchy-pkgs checkout required; set OMARCHY_PKGS_PATH'

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/source/omarchy"

# Use tracked checkout contents, not an installed desktop or the developer's
# unrelated files. Execute the real package() function, including its native
# systemd destination, rather than accepting a matching string in a comment.
git -C "$ROOT" ls-files -z config etc default applications logo.txt logo.svg icon.txt icon.png \
  bin/omarchy-upload-log bin/omarchy-debug bin/omarchy-debug-idle \
  | tar -C "$ROOT" --null -T - -cf - \
  | tar -C "$test_tmp/source/omarchy" -xf -

for flavor in omarchy omarchy-dev; do
  (
    CARCH=aarch64 OMARCHY_SRC="$test_tmp/source/omarchy"
    source "$pkgs_root/$flavor/PKGBUILD"
    printf '%s\n' "${depends[@]}" "${depends_aarch64[@]}" >"$test_tmp/$flavor.dependencies"
  )
  grep -Fx snapper "$test_tmp/$flavor.dependencies" >/dev/null || fail "$flavor requires Snapper on aarch64"
  ! grep -q '^limine' "$test_tmp/$flavor.dependencies" || fail "$flavor does not require Limine on aarch64"
done
pass 'stable and development desktop packages require Snapper, but not Limine, on aarch64'

# The default stable build uses its pinned Git commit, not OMARCHY_SRC. A
# newer checkout can require units absent from that release; exercise both
# layouts so a current-source packaging fix cannot break the stable pin.
pinned_commit=$(
  unset OMARCHY_SRC
  CARCH=aarch64
  source "$pkgs_root/omarchy-settings/PKGBUILD"
  printf '%s\n' "$_commit"
)
if git -C "$ROOT" cat-file -e "$pinned_commit^{commit}" 2>/dev/null; then
  mkdir -p "$test_tmp/pinned-source/omarchy"
  git -C "$ROOT" archive "$pinned_commit" \
    | tar -C "$test_tmp/pinned-source/omarchy" -xf -
  for flavor in omarchy-settings omarchy-settings-dev; do
    for architecture in aarch64 x86_64; do
      (
        unset OMARCHY_SRC
        CARCH=$architecture
        srcdir="$test_tmp/pinned-source" pkgdir="$test_tmp/pinned-$flavor-$architecture"
        mkdir -p "$pkgdir"
        source "$pkgs_root/$flavor/PKGBUILD"
        magick() { :; }
        package >"$test_tmp/pinned-$flavor-$architecture.output" 2>&1
        cmp "$srcdir/omarchy/default/systemd/user/bt-agent.service" "$pkgdir/usr/lib/systemd/user/bt-agent.service"
        keyboard_unit=default/systemd/user/omarchy-brightness-keyboard-auto.service
        if [[ -f $srcdir/omarchy/$keyboard_unit ]]; then
          cmp "$srcdir/omarchy/$keyboard_unit" "$pkgdir/usr/lib/systemd/user/${keyboard_unit##*/}"
        else
          [[ ! -e $pkgdir/usr/lib/systemd/user/${keyboard_unit##*/} ]] || fail 'older source does not invent a keyboard unit'
        fi
      )
      pass "$flavor/$architecture also stages the actual stable source pin $pinned_commit"
    done
  done
else
  pass "stable source pin $pinned_commit absent from local Git history; skipping pinned-source staging"
fi
for flavor in omarchy-settings omarchy-settings-dev; do
  for architecture in aarch64 x86_64; do
    (
      CARCH=$architecture OMARCHY_SRC="$test_tmp/source/omarchy"
      srcdir="$test_tmp/source" pkgdir="$test_tmp/$flavor-$architecture"
      mkdir -p "$pkgdir"
      source "$pkgs_root/$flavor/PKGBUILD"
      # Image conversion is unrelated to unit installation; retain package()
      # control flow and file staging without requiring ImageMagick in CI.
      magick() { :; }
      package >"$test_tmp/$flavor-$architecture.output" 2>&1

      systemctl() {
        [[ $* != '--user daemon-reload' ]] || return 0
        [[ ${1:-} == '--user' && ${2:-} == 'enable' && ${3:-} == '--now' ]] || return 1
        shift 3
        (( $# > 0 )) || return 1
        local unit
        for unit in "$@"; do
          [[ -f $pkgdir/usr/lib/systemd/user/$unit ]] || fail "$flavor/$architecture stages required unit $unit"
          cmp "$ROOT/default/systemd/user/$unit" "$pkgdir/usr/lib/systemd/user/$unit" \
            || fail "$flavor/$architecture installs the current $unit"
          [[ $(stat -c %a "$pkgdir/usr/lib/systemd/user/$unit") == 644 ]] \
            || fail "$flavor/$architecture unit permissions are 0644"
        done
      }
      source "$ROOT/install/user/first-run/enable-user-units.sh"
    )
    pass "$flavor/$architecture stages every unit required by actual first-run setup"
  done
done
