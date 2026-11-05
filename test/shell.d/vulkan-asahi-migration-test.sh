#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

migration="$ROOT/migrations/1789958597.sh"
[[ -f $migration ]] || fail "vulkan-asahi migration exists"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-hw-apple" <<'STUB'
#!/bin/bash
exit "${APPLE_STATUS:-0}"
STUB

cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${PKG_ADD_CALLS:?}"
STUB

chmod +x "$stub_bin"/*

run_migration() {
  rm -f "$test_tmp/pkg-add"
  APPLE_STATUS="${1:-0}" PKG_ADD_CALLS="$test_tmp/pkg-add" \
    PATH="$stub_bin:$PATH" bash -euo pipefail "$migration" >/dev/null
}

run_migration 0
grep -qxF -- 'vulkan-asahi' "$test_tmp/pkg-add" ||
  fail "Apple Silicon migration installs vulkan-asahi" "$(cat "$test_tmp/pkg-add" 2>/dev/null || true)"
pass "migration installs vulkan-asahi on Apple Silicon"

run_migration 1
[[ ! -e $test_tmp/pkg-add ]] ||
  fail "non-Apple migration still calls pkg-add" "$(cat "$test_tmp/pkg-add")"
pass "migration skips machines that are not Apple Silicon"
