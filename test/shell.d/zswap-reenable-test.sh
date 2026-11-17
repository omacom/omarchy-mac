#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1791772969.sh"
[[ -f $migration ]] || fail "the zswap re-enable migration exists"

# The tmpfiles disable is gone from the shipped tree.
[[ ! -e $ROOT/etc/tmpfiles.d/omarchy-zswap.conf ]] ||
  fail "the shipped zswap-disable tmpfiles entry is removed"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
# Log and execute directly: tee needs to write the stub node.
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
exec "$@"
STUB
chmod +x "$stub_bin/sudo"
export PATH="$stub_bin:$PATH"
export TEST_LOG="$test_tmp/sudo.log"
touch "$TEST_LOG"

conf="$test_tmp/omarchy-zswap.conf"
node="$test_tmp/enabled"
echo N >"$node"
export OMARCHY_ZSWAP_CONF="$conf"
export OMARCHY_ZSWAP_ENABLED_NODE="$node"

shipped='# Arch kernel comment
w! /sys/module/zswap/parameters/enabled - - - - N'

# Shipped conf: removed, zswap flipped on.
printf '%s\n' "$shipped" >"$conf"
bash "$migration" >/dev/null
[[ ! -f $conf ]] || fail "the shipped zswap-disable file is removed"
[[ $(cat "$node") == "Y" ]] || fail "zswap is re-enabled live"

# Admin-edited conf: kept in place, runtime left alone.
printf '# my own tuning\nw! /other/path - - - - N\n' >"$conf"
echo N >"$node"
bash "$migration" >/dev/null
[[ -f $conf ]] || fail "an admin-edited tmpfiles file is respected"
[[ $(cat "$node") == "N" ]] || fail "runtime untouched when the disable was not ours"

# Missing conf: clean no-op, runtime left alone (admin disabled by hand).
rm -f "$conf"
echo N >"$node"
bash "$migration" >/dev/null
[[ ! -f $conf ]] || fail "re-running without the file is a no-op"
[[ $(cat "$node") == "N" ]] || fail "a hand-disabled machine keeps zswap off"

# Unwritable node (read-only sysfs): tolerated, exit 0.
printf '%s\n' "$shipped" >"$conf"
chmod 0444 "$node"
bash "$migration" >/dev/null
[[ ! -f $conf ]] || fail "conf still removed when the sysfs write fails"
chmod 0644 "$node"

# Hardware detection: non-aarch64 never touches anything, even with the
# shipped conf present (the x86 fleet keeps zswap off — measured slower).
printf '%s\n' "$shipped" >"$conf"
echo N >"$node"
OMARCHY_ZSWAP_ARCH=x86_64 bash "$migration" >/dev/null
[[ -f $conf ]] || fail "x86_64 keeps the disable file (hardware detection)"
[[ $(cat "$node") == "N" ]] || fail "x86_64 keeps zswap off (hardware detection)"
pass "zswap re-enable migration removes the shipped disable and turns zswap on"
