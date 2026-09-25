#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/video-decode.sh"
all="$ROOT/install/hardware/all.sh"
migration=$(grep -rl 'Enable hardware video decode on Apple Silicon' "$ROOT/migrations" | head -n 1 || true)

[[ -f $leaf ]] || fail "the Apple Silicon video decode setup leaf ships"
grep -Fq 'apple/video-decode.sh' "$all" ||
  fail "Apple Silicon video decode setup runs during hardware setup"
[[ -n $migration ]] || fail "existing Apple Silicon installs get hardware video decode"
pass "fresh and existing installs are wired to Apple Silicon video decode setup"

list_names() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$@"
}
for package in avd-fw libva-v4l2_request-avd; do
  list_names "$ROOT/install/omarchy-apple.packages" | grep -Fxq "$package" ||
    fail "Apple Silicon images install $package from the Apple package list"
  ! list_names "$ROOT/install/omarchy-base.packages" "$ROOT/install/omarchy-other.packages" | grep -Fxq "$package" ||
    fail "$package stays out of the package lists every platform installs"
done
pass "the Apple package list, and only it, carries the decode stack"

require_platform_fixtures "the video decode platform gates"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/stubs"
calls="$test_tmp/calls.log"
installed_marker="$test_tmp/avd-installed"
mkdir -p "$stub_bin"
for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$test_tmp/$platform" "$platform"
done

cat >"$stub_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash

[[ ! -e $AVD_INSTALLED_MARKER ]]
SH

cat >"$stub_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash

[[ -e $AVD_INSTALLED_MARKER ]]
SH

cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash

printf 'omarchy-pkg-add' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
if (( ${PACKAGE_INSTALL_SUCCEEDS:-1} == 1 )); then
  touch "$AVD_INSTALLED_MARKER"
fi
exit 0
SH

cat >"$stub_bin/omarchy-state" <<'SH'
#!/bin/bash

printf 'omarchy-state' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
SH

chmod +x "$stub_bin"/*

run_video_setup() {
  local script="$1" platform="$2" install_succeeds="${3:-1}" fixture="$test_tmp/$2"

  PATH="$fixture/bin:$stub_bin:$ROOT/bin:$PATH" \
    OMARCHY_PROC_ROOT="$fixture/proc" \
    TEST_LOG="$calls" \
    AVD_INSTALLED_MARKER="$installed_marker" \
    PACKAGE_INSTALL_SUCCEEDS="$install_succeeds" \
    OMARCHY_PATH="$ROOT" \
    bash -euo pipefail -c 'source "$1"' bash "$script" >/dev/null
}

: >"$calls"
run_video_setup "$leaf" apple-silicon

expected_call=$'omarchy-pkg-add\tavd-fw\tlibva-v4l2_request-avd'
grep -Fxq "$expected_call" "$calls" ||
  fail "fresh Apple Silicon installs get the firmware and the VA-API driver" "$(cat "$calls")"
pass "fresh Apple Silicon installs get the firmware and the VA-API driver"

run_video_setup "$leaf" apple-silicon
(( $(grep -Fxc "$expected_call" "$calls") == 1 )) ||
  fail "fresh Apple Silicon video decode setup is idempotent" "$(cat "$calls")"
pass "fresh Apple Silicon video decode setup is idempotent"

rm -f "$installed_marker"
: >"$calls"
run_video_setup "$migration" apple-silicon
grep -Fxq "$expected_call" "$calls" ||
  fail "the migration enables video decode on an existing install" "$(cat "$calls")"
expected_reboot=$'omarchy-state\tset\treboot-required'
grep -Fxq "$expected_reboot" "$calls" ||
  fail "the migration requests the reboot that lets the driver probe" "$(cat "$calls")"

run_video_setup "$migration" apple-silicon
(( $(grep -Fxc "$expected_call" "$calls") == 1 )) ||
  fail "the Apple Silicon video decode migration is idempotent" "$(cat "$calls")"
(( $(grep -Fxc "$expected_reboot" "$calls") == 1 )) ||
  fail "an already enabled install does not request another reboot" "$(cat "$calls")"
pass "the migration enables existing Apple Silicon installs idempotently"

rm -f "$installed_marker"
: >"$calls"
errors="$test_tmp/errors.log"
run_video_setup "$leaf" apple-silicon 0 2>"$errors" ||
  fail "an incomplete install does not abort hardware setup" "$(cat "$errors")"
grep -Fq 'hardware video decode stack is incomplete' "$errors" ||
  fail "fresh setup explains the incomplete video decode stack" "$(cat "$errors")"

: >"$calls"
: >"$errors"
run_video_setup "$migration" apple-silicon 0 2>"$errors" ||
  fail "an incomplete install does not abort the migration" "$(cat "$errors")"
! grep -Fq 'reboot-required' "$calls" ||
  fail "an incomplete install does not ask for a pointless reboot" "$(cat "$calls")"
pass "an incomplete package install warns instead of aborting"

rm -f "$installed_marker"
: >"$calls"
for platform in qualcomm generic-aarch64 generic; do
  run_video_setup "$leaf" "$platform"
  run_video_setup "$migration" "$platform"
done
[[ ! -s $calls ]] ||
  fail "Apple Silicon video decode setup skips Qualcomm, other ARM and x86" "$(cat "$calls")"
pass "Apple Silicon video decode setup skips Qualcomm, other ARM and x86"
