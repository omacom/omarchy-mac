#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/user/hardware/apple/share-picker.sh"
all="$ROOT/install/user/all.sh"
migration="$ROOT/migrations/1789140928.sh"
git_drop="$ROOT/migrations/1789228235.sh"
flags="$ROOT/config/chromium-flags.conf"

grep -Fq 'hardware/apple/share-picker.sh' "$all" ||
  fail "the share-picker leaf runs during user setup"
[[ -f $migration ]] || fail "existing installs get the share-picker migration"
[[ -f $git_drop ]] || fail "existing -git installs get a replacement migration"
grep -Fq 'hyprland-preview-share-picker-git' "$git_drop" ||
  fail "the replacement migration drops hyprland-preview-share-picker-git"
! grep -Fq 'WebRTCPipeWireCapturer' "$flags" ||
  fail "shipped Chromium flags must not force the PipeWire capturer on x86"
pass "fresh and existing installs are wired to the screen-share picker"

require_platform_fixtures "the share-picker platform gates"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
calls="$test_tmp/calls.log"
for platform in apple-silicon qualcomm generic; do
  fake_platform "$test_tmp/$platform" "$platform"
done

# $1 is the platform, $2 the script, $3 how to run it.
run_on() {
  local platform="$1" script="$2" mode="${3:-source}" fixture="$test_tmp/$1"
  : >"$calls"
  if [[ $mode == "source" ]]; then
    TEST_LOG="$calls" HOME="$test_tmp/home" OMARCHY_PROC_ROOT="$fixture/proc" PATH="$fixture/bin:$ROOT/bin:$PATH" \
      bash -c 'source "$1"' _ "$script"
  else
    TEST_LOG="$calls" HOME="$test_tmp/home" OMARCHY_PROC_ROOT="$fixture/proc" PATH="$fixture/bin:$ROOT/bin:$PATH" \
      bash -euo pipefail "$script"
  fi
}

run_on generic "$leaf"
[[ ! -s $calls ]] || fail "x86 does not touch the share picker" "$(cat "$calls")"
pass "x86 leaves the packaged picker alone"

! grep -Fq 'hyprland-preview-share-picker-git' "$leaf" "$migration" ||
  fail "the share-picker leaf and migration no longer AUR-build -git"
pass "Apple Silicon uses the packaged hyprland-preview-share-picker"

conf="$test_tmp/home/.config/chromium-flags.conf"
mkdir -p "$(dirname "$conf")"
for platform in generic qualcomm; do
  printf '%s\n' '--enable-features=TouchpadOverscrollHistoryNavigation' >"$conf"
  run_on "$platform" "$leaf"
  ! grep -Fq 'WebRTCPipeWireCapturer' "$conf" ||
    fail "the share-picker leaf must not rewrite $platform Chromium flags"

  printf '%s\n' '--enable-features=TouchpadOverscrollHistoryNavigation' >"$conf"
  run_on "$platform" "$migration" run
  ! grep -Fq 'WebRTCPipeWireCapturer' "$conf" ||
    fail "the migration must not rewrite $platform Chromium flags"
done
pass "the share-picker leaf and migration leave x86 and Qualcomm Chromium flags alone"

printf '%s\n' '--enable-features=TouchpadOverscrollHistoryNavigation' >"$conf"
run_on apple-silicon "$leaf"
grep -Fq 'WebRTCPipeWireCapturer' "$conf" ||
  fail "a fresh Apple Silicon install enables PipeWire capture on existing Chromium flags"
pass "a fresh Apple Silicon install enables PipeWire capture on existing Chromium flags"

printf '%s\n' '--enable-features=TouchpadOverscrollHistoryNavigation' >"$conf"
run_on apple-silicon "$migration" run
grep -Fq 'WebRTCPipeWireCapturer' "$conf" ||
  fail "the migration enables PipeWire capture on existing Apple Silicon Chromium flags"
pass "the migration enables PipeWire capture on existing Apple Silicon Chromium flags"
