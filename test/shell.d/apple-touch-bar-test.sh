#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/touch-bar.sh"
migration="$ROOT/migrations/1792363343.sh"

grep -Fxq 'run_logged "$OMARCHY_INSTALL/hardware/apple/touch-bar.sh"' "$ROOT/install/hardware/all.sh" ||
  fail "the Touch Bar daemon is installed during hardware setup"
grep -Fq 'Install the Touch Bar daemon' "$migration" ||
  fail "existing installs get the Touch Bar daemon"
pass "fresh and existing installs are wired to the Touch Bar daemon setup"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
compatible="$test_tmp/compatible"
installed_marker="$test_tmp/tiny-dfr-installed"
mkdir -p "$stub_bin"

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash

printf '%s\n' "$TEST_ARCH"
SH

cat >"$stub_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash

[[ ! -e $INSTALLED_MARKER ]]
SH

cat >"$stub_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash

[[ -e $INSTALLED_MARKER ]]
SH

cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash

printf 'omarchy-pkg-add' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
touch "$INSTALLED_MARKER"
SH

cat >"$stub_bin/omarchy-state" <<'SH'
#!/bin/bash

printf 'omarchy-state' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
SH

chmod +x "$stub_bin"/*

# The real predicates are used; only the machine they read is faked.
run_script() {
  local script="$1" arch="$2"
  shift 2
  printf '%s\0' "$@" >"$compatible"

  PATH="$stub_bin:$ROOT/bin:$PATH" \
    TEST_ARCH="$arch" \
    TEST_LOG="$calls" \
    INSTALLED_MARKER="$installed_marker" \
    OMARCHY_APPLE_COMPATIBLE="$compatible" \
    OMARCHY_PATH="$ROOT" \
    bash -euo pipefail -c 'source "$1"' bash "$script" >/dev/null
}

predicate() {
  local arch="$1"
  shift
  printf '%s\0' "$@" >"$compatible"
  PATH="$stub_bin:$ROOT/bin:$PATH" TEST_ARCH="$arch" OMARCHY_APPLE_COMPATIBLE="$compatible" \
    "$ROOT/bin/omarchy-hw-apple-touch-bar"
}

predicate aarch64 apple,j293 apple,t8103 apple,arm-platform || fail "the 13-inch M1 MacBook Pro has a Touch Bar"
predicate aarch64 apple,j493 apple,t8112 apple,arm-platform || fail "the 13-inch M2 MacBook Pro has a Touch Bar"
if predicate aarch64 apple,j314s apple,t6000 apple,arm-platform; then
  fail "a 14-inch MacBook Pro has no Touch Bar"
fi
if predicate aarch64 apple,j2930 apple,arm-platform; then
  fail "a board name that only starts with j293 is not a Touch Bar Mac"
fi
# Neighbouring board numbers must not match: only j293 and j493 have the panel.
for board in apple,j294 apple,j494 apple,j193; do
  if predicate aarch64 "$board" apple,arm-platform; then
    fail "$board is not a Touch Bar Mac"
  fi
done
if predicate x86_64 apple,j293; then
  fail "a non-aarch64 machine is not an Apple Silicon Touch Bar Mac"
fi
rm "$compatible"
if PATH="$stub_bin:$ROOT/bin:$PATH" TEST_ARCH=aarch64 OMARCHY_APPLE_COMPATIBLE="$compatible" "$ROOT/bin/omarchy-hw-apple-touch-bar"; then
  fail "a machine without a device tree has no Touch Bar"
fi
pass "only the 13-inch M1 and M2 MacBook Pros are detected as having a Touch Bar"

: >"$calls"
run_script "$leaf" aarch64 apple,j293 apple,arm-platform
[[ $(<"$calls") == $'omarchy-pkg-add\ttiny-dfr' ]] ||
  fail "a fresh Touch Bar Mac install gets tiny-dfr" "$(<"$calls")"
run_script "$leaf" aarch64 apple,j293 apple,arm-platform
(( $(grep -c . "$calls") == 1 )) ||
  fail "hardware setup does not reinstall tiny-dfr" "$(<"$calls")"
pass "fresh installs add tiny-dfr once on Touch Bar Macs"

rm -f "$installed_marker"
: >"$calls"
run_script "$leaf" aarch64 apple,j314s apple,arm-platform
[[ ! -s $calls ]] || fail "Macs without a Touch Bar install nothing" "$(<"$calls")"
pass "other Macs install nothing"

: >"$calls"
run_script "$migration" aarch64 apple,j493 apple,arm-platform
[[ $(<"$calls") == $'omarchy-pkg-add\ttiny-dfr\nomarchy-state\tset\treboot-required' ]] ||
  fail "the migration adds tiny-dfr and asks for a reboot" "$(<"$calls")"
: >"$calls"
run_script "$migration" aarch64 apple,j493 apple,arm-platform
[[ ! -s $calls ]] || fail "an installed Touch Bar Mac does not ask for another reboot" "$(<"$calls")"

rm -f "$installed_marker"
: >"$calls"
run_script "$migration" aarch64 apple,j314s apple,arm-platform
[[ ! -s $calls ]] || fail "the migration leaves Macs without a Touch Bar alone" "$(<"$calls")"
pass "the migration adds tiny-dfr and a reboot request only where it is missing on Touch Bar Macs"
