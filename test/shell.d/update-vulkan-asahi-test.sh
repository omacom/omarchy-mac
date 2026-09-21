#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin" "$test_tmp/omarchy/install/helpers"

cat >"$stub_bin/uname" <<'STUB'
#!/bin/bash
printf '%s\n' aarch64
STUB

cat >"$test_tmp/omarchy/install/helpers/arm-package-sources.sh" <<'STUB'
source "$ROOT/install/helpers/arm-package-sources.sh"
omarchy_arm_prepare_package_sources() { :; }
STUB

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB

cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
if [[ ${1:-} == "--config" && ${3:-} == "-Q" ]]; then
  case "${4:-}" in asdcontrol | tobi-try) exit 1 ;; esac
fi
printf '%s\n' "$*" >>"$PACMAN_CALLS"
STUB

chmod +x "$stub_bin"/*

apple_dt="$test_tmp/apple"
other_dt="$test_tmp/other"
printf 'apple,j313\0apple,t8103\0' >"$apple_dt"
printf 'linux,dummy\0' >"$other_dt"

run_update() {
  local compatible="$1"
  : >"$test_tmp/calls"
  OMARCHY_PATH="$test_tmp/omarchy" \
    OMARCHY_APPLE_COMPATIBLE="$compatible" \
    PACMAN_CALLS="$test_tmp/calls" \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    bash "$ROOT/bin/omarchy-update-system-pkgs" \
    >"$test_tmp/out" 2>"$test_tmp/err"
}

run_update "$apple_dt"
grep -q -- '-Syu' "$test_tmp/calls" || fail "Apple Silicon update still runs -Syu" "$(cat "$test_tmp/calls")"
grep -q -- 'vulkan-asahi' "$test_tmp/calls" ||
  fail "Apple Silicon -Syu does not name vulkan-asahi" "$(cat "$test_tmp/calls")"
grep -q -- 'omarchy/hyprland' "$test_tmp/calls" ||
  fail "Apple Silicon -Syu drops the ARM compositor targets" "$(cat "$test_tmp/calls")"
ignore_list=$(grep -o -- '--ignore [^ ]*' "$test_tmp/calls" || true)
[[ $ignore_list != *vulkan-asahi* ]] ||
  fail "vulkan-asahi is ignored out of extra" "$(cat "$test_tmp/calls")"
pass "Apple Silicon -Syu requests vulkan-asahi by name"

run_update "$other_dt"
grep -q -- '-Syu' "$test_tmp/calls" || fail "non-Apple aarch64 update still runs -Syu" "$(cat "$test_tmp/calls")"
! grep -q -- 'vulkan-asahi' "$test_tmp/calls" ||
  fail "non-Apple aarch64 -Syu still requests vulkan-asahi" "$(cat "$test_tmp/calls")"
pass "non-Apple aarch64 -Syu does not request vulkan-asahi"

# The provide-hiding bug: mesa 26.1 satisfies pacman -Q vulkan-asahi. The
# update must still put the real package on argv.
cat >"$stub_bin/omarchy-pkg-missing" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$stub_bin/omarchy-pkg-missing"
run_update "$apple_dt"
grep -q -- 'vulkan-asahi' "$test_tmp/calls" ||
  fail "vulkan-asahi is omitted when a provide makes pkg-missing false" "$(cat "$test_tmp/calls")"
pass "mesa providing vulkan-asahi does not drop the explicit -Syu target"
