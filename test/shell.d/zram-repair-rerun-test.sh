#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1791089325.sh"
[[ -f $migration ]] || fail "the zram repair re-run migration exists"

# The runner keys pending work on marker filenames, so the repair must ship
# under a name no pre-marked install has seen.
[[ $migration != "$ROOT/migrations/1787669934.sh" ]] ||
  fail "the re-run migration is not an in-place edit of 1787669934.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
swap_active="$test_tmp/dev-zram0.swap.active"
test_root="$test_tmp/omarchy"
mkdir -p "$stub_bin" "$test_root/migrations" "$test_root/install/helpers"
cp "$ROOT/install/helpers/zram.sh" "$test_root/install/helpers/zram.sh"
cp "$migration" "$test_root/migrations/"
mkdir -p "$test_root/default/systemd/zram-generator.conf.d"
cp "$ROOT/default/systemd/zram-generator.conf.d/90-omarchy.conf" \
  "$test_root/default/systemd/zram-generator.conf.d/90-omarchy.conf"
export OMARCHY_PATH="$test_root"
export OMARCHY_ZRAM_ROOT="$test_tmp/system"
export TEST_ZRAM_INSTALLED="$test_tmp/zram-generator.installed"

cat >"$stub_bin/omarchy-pkg-missing" <<'STUB'
#!/bin/bash
printf 'missing %s\n' "$*" >>"$TEST_LOG"
(( ${OMARCHY_TEST_ZRAM_MISSING:-1} == 1 )) && [[ ! -e $TEST_ZRAM_INSTALLED ]]
STUB

cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
printf 'add %s\n' "$*" >>"$TEST_LOG"
(( ${TEST_PACKAGE_STATUS:-0} == 0 )) || exit "$TEST_PACKAGE_STATUS"
touch "$TEST_ZRAM_INSTALLED"
STUB

cat >"$stub_bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"

case "$1" in
  is-active)
    [[ $2 == "--quiet" && $3 == "dev-zram0.swap" && -e $TEST_SWAP_ACTIVE ]]
    ;;
  start)
    [[ $2 == "dev-zram0.swap" ]] || exit 1
    touch "$TEST_SWAP_ACTIVE"
    ;;
  show)
    [[ $* == "show --property=LoadState --value dev-zram0.swap" ]] || exit 1
    if [[ -n ${TEST_LOAD_STATE:-} ]]; then
      printf '%s\n' "$TEST_LOAD_STATE"
    elif [[ -f $OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf ]]; then
      echo loaded
    else
      echo not-found
    fi
    ;;
esac
STUB

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
exec "$@"
STUB

chmod +x "$stub_bin"/*

run_migration() {
  : >"$calls"
  rm -f "$swap_active" "$TEST_ZRAM_INSTALLED"
  set +e
  PATH="$stub_bin:$PATH" TEST_LOG="$calls" TEST_SWAP_ACTIVE="$swap_active" \
    OMARCHY_TEST_ZRAM_MISSING="$1" bash -euo pipefail "$migration" >/dev/null 2>&1
  local status=$?
  set -e
  return "$status"
}

# Unconfigured machine, generator missing: installs, writes fallback config,
# reloads before starting, starts the swap unit.
run_migration 1 ||
  fail "the re-run migration succeeds when it can install zram-generator"
grep -Fx 'add zram-generator' "$calls" >/dev/null ||
  fail "the re-run migration installs a missing zram-generator"
cmp "$test_root/default/systemd/zram-generator.conf.d/90-omarchy.conf" \
  "$OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf" ||
  fail "the re-run migration installs fallback configuration"
reload_line=$(awk '$0 == "sudo systemctl daemon-reload" { print NR; exit }' "$calls")
start_line=$(awk '$0 == "sudo systemctl start dev-zram0.swap" { print NR; exit }' "$calls")
[[ -n $reload_line && -n $start_line ]] ||
  fail "the re-run migration records both systemd calls"
(( reload_line < start_line )) ||
  fail "the re-run migration reloads systemd before starting zram"

# Already-configured machine: existing config is an administrator's choice.
mkdir -p "$OMARCHY_ZRAM_ROOT/etc/systemd"
: >"$OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf"
run_migration 0 ||
  fail "the re-run migration succeeds with the generator installed"
grep -Fx 'sudo install -D -m 0644' "$calls" >/dev/null &&
  fail "the re-run migration never replaces an existing zram config"
rm -f "$OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf"

# Generator uninstallable: exit nonzero so the marker is not written and the
# repair retries on the next update.
: >"$calls"
rm -f "$TEST_ZRAM_INSTALLED"
set +e
PATH="$stub_bin:$PATH" TEST_LOG="$calls" TEST_SWAP_ACTIVE="$swap_active" \
  OMARCHY_TEST_ZRAM_MISSING=1 TEST_PACKAGE_STATUS=1 \
  bash -euo pipefail "$migration" >/dev/null 2>&1
status=$?
set -e
(( status != 0 )) ||
  fail "the re-run migration retries when zram-generator cannot be installed"

pass "zram repair re-run migration repairs pre-marked machines"
