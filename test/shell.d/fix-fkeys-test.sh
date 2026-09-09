#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/fix-fkeys.sh"

grep -qF 'omarchy-hw-apple-silicon' "$leaf" ||
  fail "fnmode setup keys off Apple Silicon, not a generic uname"
grep -qF 'modinfo hid_apple' "$leaf" &&
  fail "fnmode setup must not treat a shipped hid_apple module as Apple hardware" || true
grep -qF '/sys/module/hid_apple' "$leaf" ||
  fail "fnmode setup treats a loaded hid_apple module as T2/in-use evidence"
pass "fnmode setup does not leak onto generic x86 via modinfo"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
conf="$test_tmp/hid_apple.conf"
module="$test_tmp/module"
mkdir -p "$stub_bin"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
"$@"
SH
chmod +x "$stub_bin/sudo"

run_leaf() {
  local arch="$1" apple_dt="$2" loaded="$3"
  rm -f "$conf"
  rm -rf "$module"
  (( loaded == 1 )) && mkdir -p "$module"
  printf '%s\n' "$apple_dt" >"$test_tmp/compatible"

  PATH="$stub_bin:$ROOT/bin:$PATH" \
    OMARCHY_UNAME_M="$arch" \
    OMARCHY_APPLE_COMPATIBLE="$test_tmp/compatible" \
    OMARCHY_HID_APPLE_MODULE_PATH="$module" \
    OMARCHY_HID_APPLE_CONF_PATH="$conf" \
    bash -euo pipefail -c 'source "$1"' bash "$leaf"
}

run_leaf x86_64 'apple,j413' 0
[[ ! -f $conf ]] || fail "x86 without a loaded hid_apple module is left alone" "$(cat "$conf")"
pass "x86 without a loaded hid_apple module is left alone"

run_leaf x86_64 'not-apple' 1
[[ -f $conf ]] || fail "x86 with hid_apple loaded gets fnmode=2"
grep -qF 'fnmode=2' "$conf" || fail "x86 fnmode write is fnmode=2" "$(cat "$conf")"
pass "x86 with hid_apple loaded gets upstream fnmode=2"

run_leaf aarch64 'apple,j413' 0
[[ -f $conf ]] || fail "Apple Silicon gets fnmode=1 even before hid_apple loads"
grep -qx 'options hid_apple fnmode=1' "$conf" || fail "Apple Silicon fnmode write is fnmode=1" "$(cat "$conf")"
pass "Apple Silicon gets fnmode=1 even before hid_apple loads"

run_leaf aarch64 'raspberrypi,4-model-b' 0
[[ ! -f $conf ]] || fail "non-Apple aarch64 is left alone" "$(cat "$conf")"
pass "non-Apple aarch64 is left alone"

run_leaf aarch64 'raspberrypi,4-model-b' 1
[[ ! -f $conf ]] || fail "non-Apple aarch64 with hid_apple loaded is left alone" "$(cat "$conf")"
pass "non-Apple aarch64 does not take the x86 fnmode setting"

run_leaf riscv64 'not-apple' 1
[[ ! -f $conf ]] || fail "unknown architecture with hid_apple loaded is left alone" "$(cat "$conf")"
pass "unknown architecture does not take the x86 fnmode setting"

omarchy-hw-arch() { return 127; }
export -f omarchy-hw-arch
run_leaf x86_64 'not-apple' 1
unset -f omarchy-hw-arch
[[ ! -f $conf ]] || fail "missing architecture detector must not set x86 fnmode"
pass "missing architecture detection leaves loaded hid_apple alone"
