#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/uname" <<'STUB'
#!/bin/bash
printf '%s\n' aarch64
STUB

cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${PKG_ADD_CALLS:?}"
STUB

cat >"$stub_bin/lspci" <<'STUB'
#!/bin/bash
exit 1
STUB

chmod +x "$stub_bin"/*

apple_dt="$test_tmp/apple"
other_dt="$test_tmp/other"
printf 'apple,j313\0' >"$apple_dt"
printf 'linux,dummy\0' >"$other_dt"

run_vulkan_sh() {
  local compatible="$1"
  rm -f "$test_tmp/pkg-add"
  OMARCHY_APPLE_COMPATIBLE="$compatible" PKG_ADD_CALLS="$test_tmp/pkg-add" \
    PATH="$stub_bin:$PATH" bash -euo pipefail -c 'source "$1"' _ "$ROOT/install/hardware/vulkan.sh"
}

run_vulkan_sh "$apple_dt"
grep -qxF -- 'vulkan-asahi' "$test_tmp/pkg-add" ||
  fail "install-time vulkan.sh adds vulkan-asahi on Apple Silicon" "$(cat "$test_tmp/pkg-add" 2>/dev/null || true)"
pass "install-time vulkan.sh adds vulkan-asahi on Apple Silicon"

run_vulkan_sh "$other_dt"
[[ ! -e $test_tmp/pkg-add ]] ||
  fail "install-time vulkan.sh adds vulkan-asahi off Apple Silicon" "$(cat "$test_tmp/pkg-add")"
pass "install-time vulkan.sh skips vulkan-asahi off Apple Silicon"
