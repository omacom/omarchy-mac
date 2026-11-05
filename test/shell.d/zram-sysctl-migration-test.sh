#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

migration="$ROOT/migrations/1789959833.sh"
[[ -f $migration ]] || fail "zram sysctl migration exists"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/uname" <<'STUB'
#!/bin/bash
printf '%s\n' "${TEST_ARCH:-aarch64}"
STUB

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"${TEST_CALLS:?}"
exec "$@"
STUB

cat >"$stub_bin/sysctl" <<'STUB'
#!/bin/bash
printf 'sysctl %s\n' "$*" >>"${TEST_CALLS:?}"
STUB

chmod +x "$stub_bin"/*

run_migration() {
  : >"$test_tmp/calls"
  TEST_ARCH="${1:-aarch64}" TEST_CALLS="$test_tmp/calls" \
    OMARCHY_PATH="$ROOT" \
    OMARCHY_ZRAM_ROOT="$test_tmp/system" \
    PATH="$stub_bin:$PATH" \
    bash -euo pipefail "$migration" >/dev/null
}

sysctl_file="$test_tmp/system/etc/sysctl.d/99-omarchy-zram.conf"

run_migration
[[ ! -e $sysctl_file ]] || fail "migration writes sysctl without zram config"
! grep -q '^sudo ' "$test_tmp/calls" || fail "no-zram migration still uses sudo" "$(cat "$test_tmp/calls")"
pass "migration skips machines without zram configuration"

mkdir -p "$test_tmp/system/etc/systemd"
printf '[zram0]\n' >"$test_tmp/system/etc/systemd/zram-generator.conf"

run_migration x86_64
[[ ! -e $sysctl_file ]] || fail "x86 migration still writes ARM zram sysctl"
pass "migration skips x86_64 even when zram is configured"

run_migration
grep -qx 'vm.swappiness=150' "$sysctl_file" || fail "migration writes vm.swappiness=150"
grep -qx 'vm.page-cluster=0' "$sysctl_file" || fail "migration writes vm.page-cluster=0"
grep -q -- "-p $sysctl_file" "$test_tmp/calls" ||
  fail "migration loads the drop-in into the running kernel" "$(cat "$test_tmp/calls")"
pass "migration installs zram reclaim tunings on aarch64"

: >"$test_tmp/calls"
run_migration
! grep -q '^sudo ' "$test_tmp/calls" ||
  fail "second run still writes after tunings are present" "$(cat "$test_tmp/calls")"
pass "migration is idempotent once the drop-in exists"

rm -f "$sysctl_file"
printf 'vm.swappiness=10\n' >"$sysctl_file"
run_migration
grep -qx 'vm.swappiness=10' "$sysctl_file" || fail "migration overwrote an existing sysctl drop-in"
! grep -qx 'vm.swappiness=150' "$sysctl_file" || fail "migration merged tunings into an existing drop-in"
pass "migration keeps an administrator-owned drop-in"
