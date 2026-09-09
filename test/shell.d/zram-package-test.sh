#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1787669934.sh"
[[ -f $migration ]] || fail "the zram package repair migration exists"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
swap_active="$test_tmp/dev-zram0.swap.active"
test_root="$test_tmp/omarchy"
first_home="$test_tmp/first-user-home"
second_home="$test_tmp/second-user-home"
migration_name=$(basename "$migration")
first_marker="$first_home/.local/state/omarchy/migrations/$migration_name"
second_marker="$second_home/.local/state/omarchy/migrations/$migration_name"
mkdir -p "$stub_bin" "$test_root/migrations"
cp "$migration" "$test_root/migrations/$migration_name"
mkdir -p "$test_root/default/systemd/zram-generator.conf.d"
cp "$ROOT/default/systemd/zram-generator.conf.d/90-omarchy.conf" \
  "$test_root/default/systemd/zram-generator.conf.d/90-omarchy.conf"
export OMARCHY_PATH="$test_root"
export OMARCHY_ZRAM_ROOT="$test_tmp/system"

cat >"$stub_bin/omarchy-pkg-missing" <<'STUB'
#!/bin/bash
printf 'missing %s\n' "$*" >>"$TEST_LOG"
(( ${OMARCHY_TEST_ZRAM_MISSING:-1} == 1 ))
STUB

cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
printf 'add %s\n' "$*" >>"$TEST_LOG"
exit "${TEST_PACKAGE_STATUS:-0}"
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
    (( ${TEST_START_STATUS:-0} == 0 )) || exit "$TEST_START_STATUS"
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
if [[ $1 == "install" ]] && (( ${TEST_INSTALL_STATUS:-0} != 0 )); then
  exit "$TEST_INSTALL_STATUS"
fi
exec "$@"
STUB

cat >"$stub_bin/omarchy-notification-dismiss" <<'STUB'
#!/bin/bash
exit 0
STUB

chmod +x "$stub_bin"/*

assert_systemd_start_follows_reload() {
  local reload_line start_line

  reload_line=$(awk '$0 == "systemctl daemon-reload" { print NR; exit }' "$calls")
  start_line=$(awk '$0 == "systemctl start dev-zram0.swap" { print NR; exit }' "$calls")
  [[ -n $reload_line && -n $start_line ]] ||
    fail "the zram migration records both systemd calls"
  (( reload_line < start_line )) ||
    fail "the zram migration reloads systemd before starting zram"
}

run_migration() {
  : >"$calls"
  rm -f "$swap_active"
  PATH="$stub_bin:$PATH" TEST_LOG="$calls" TEST_SWAP_ACTIVE="$swap_active" \
    OMARCHY_TEST_ZRAM_MISSING="$1" bash -euo pipefail "$migration" >/dev/null
}

run_migration 1
grep -Fx 'missing zram-generator' "$calls" >/dev/null ||
  fail "the zram migration checks whether zram-generator is installed"
grep -Fx 'add zram-generator' "$calls" >/dev/null ||
  fail "the zram migration installs a missing zram-generator"
grep -Fx 'systemctl daemon-reload' "$calls" >/dev/null ||
  fail "the zram migration reloads systemd after installing zram-generator"
grep -Fx 'systemctl start dev-zram0.swap' "$calls" >/dev/null ||
  fail "the zram migration starts the configured zram device"
cmp "$test_root/default/systemd/zram-generator.conf.d/90-omarchy.conf" \
  "$OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf" ||
  fail "the migration installs fallback configuration"
[[ ! -e $OMARCHY_ZRAM_ROOT/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf ]] ||
  fail "the migration leaves the vendor destination to the settings package"
assert_systemd_start_follows_reload
pass "the zram migration repairs an existing install without zram-generator"

run_migration 0
! grep -Fx 'add zram-generator' "$calls" >/dev/null ||
  fail "the zram migration does not reinstall an existing zram-generator"
grep -Fx 'systemctl start dev-zram0.swap' "$calls" >/dev/null ||
  fail "the zram migration starts zram when the package is already installed"
! grep -q '^sudo install ' "$calls" || fail "the migration does not reinstall existing configuration"
assert_systemd_start_follows_reload
pass "the zram migration is idempotent"

run_user_migrations() {
  local task_home="$1" zram_missing="$2"

  HOME="$task_home" OMARCHY_PATH="$test_root" PATH="$stub_bin:$PATH" \
    TEST_LOG="$calls" TEST_SWAP_ACTIVE="$swap_active" \
    OMARCHY_TEST_ZRAM_MISSING="$zram_missing" \
    "$ROOT/bin/omarchy-migrate" >/dev/null
}

rm -f "$swap_active"
: >"$calls"
run_user_migrations "$first_home" 1
[[ -e $swap_active ]] || fail "the first user activates zram" "$(cat "$calls")"
[[ -e $first_marker ]] || fail "the first user records the zram migration"

: >"$calls"
run_user_migrations "$second_home" 0
[[ -e $second_marker ]] || fail "the second user records the zram migration"
! grep -q '^sudo ' "$calls" ||
  fail "the second user does not repeat privileged zram activation" "$(cat "$calls")"
! grep -Fx 'systemctl daemon-reload' "$calls" >/dev/null ||
  fail "the second user does not reload systemd" "$(cat "$calls")"
! grep -Fx 'systemctl start dev-zram0.swap' "$calls" >/dev/null ||
  fail "the second user does not restart zram" "$(cat "$calls")"
pass "a second user completes the migration without privileged activation"

export OMARCHY_ZRAM_ROOT="$test_tmp/active-without-config"
: >"$calls"
PATH="$stub_bin:$PATH" TEST_LOG="$calls" TEST_SWAP_ACTIVE="$swap_active" \
  OMARCHY_TEST_ZRAM_MISSING=0 bash -euo pipefail "$migration" >/dev/null
[[ -f $OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf ]] ||
  fail "an active device still gets persistent configuration for the next boot"
! grep -q '^systemctl start ' "$calls" || fail "do not restart active swap after repairing configuration"
pass "active swap does not hide missing persistent configuration"

# Configuration at any supported level must prevent fallback installation,
# including empty files and symlinks used to mask vendor defaults.
for directory in etc run usr/local/lib usr/lib; do
  for suffix in zram-generator.conf zram-generator.conf.d/99-local.conf; do
    export OMARCHY_ZRAM_ROOT="$test_tmp/preserved-$directory-$suffix"
    config="$OMARCHY_ZRAM_ROOT/$directory/systemd/$suffix"
    mkdir -p "$(dirname "$config")"
    printf '[zram0]\nzram-size = ram / 4\n' >"$config"
    cp "$config" "$test_tmp/expected.conf"
    TEST_LOAD_STATE=loaded run_migration 0
    cmp "$config" "$test_tmp/expected.conf" || fail "preserve $directory/$suffix"
    ! grep -q '^sudo install ' "$calls" || fail "do not supplement $directory/$suffix"
    [[ -e $swap_active ]] || fail "activate configured swap in $directory/$suffix"
  done
done
pass "existing main files and drop-ins are preserved at every configuration level"

for disabled in empty zero-size mask dangling-mask; do
  export OMARCHY_ZRAM_ROOT="$test_tmp/disabled-$disabled"
  config="$OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf.d/90-omarchy.conf"
  mkdir -p "$(dirname "$config")"
  case "$disabled" in
    empty) touch "$config" ;;
    zero-size) printf '[zram0]\nzram-size = 0\n' >"$config" ;;
    mask) ln -s /dev/null "$config" ;;
    dangling-mask) ln -s "$test_tmp/absent" "$config" ;;
  esac
  TEST_LOAD_STATE=not-found run_migration 0
  [[ ! -e $swap_active ]] || fail "do not start absent swap for $disabled config"
  ! grep -q '^sudo install ' "$calls" || fail "do not replace $disabled config"
  [[ -e $config || -L $config ]] || fail "keep $disabled config"
done
TEST_LOAD_STATE=masked run_migration 0
[[ ! -e $swap_active ]] || fail "do not start masked swap"
pass "disabled configuration and masked units do not block the migration"

export OMARCHY_ZRAM_ROOT="$test_tmp/package-failure"
if TEST_PACKAGE_STATUS=1 run_migration 1; then
  fail "package installation errors must fail the migration"
fi
! grep -q '^sudo ' "$calls" || fail "stop immediately after package installation fails"

export OMARCHY_ZRAM_ROOT="$test_tmp/install-failure"
if TEST_INSTALL_STATUS=1 run_migration 0; then
  fail "configuration installation errors must fail the migration"
fi
! grep -q '^systemctl ' "$calls" || fail "stop immediately after configuration installation fails"

export OMARCHY_ZRAM_ROOT="$test_tmp/start-failure"
if TEST_START_STATUS=1 run_migration 0; then
  fail "swap activation errors must fail the migration"
fi
[[ ! -e $swap_active ]] || fail "failed activation must not count as active swap"
pass "package, configuration, and swap activation failures remain failures"

# When available, run the real generator in its unprivileged test mode. This
# verifies the fallback produces an actual swap unit and setup dependency,
# rather than relying only on the systemctl stub's idea of valid configuration.
generator=/usr/lib/systemd/system-generators/zram-generator
if [[ -x $generator ]]; then
  export OMARCHY_ZRAM_ROOT="$test_tmp/real-generator"
  output="$test_tmp/generated"
  mkdir -p "$OMARCHY_ZRAM_ROOT/proc" "$output"
  printf 'MemTotal: 8388608 kB\n' >"$OMARCHY_ZRAM_ROOT/proc/meminfo"
  : >"$OMARCHY_ZRAM_ROOT/proc/cmdline"
  ZRAM_GENERATOR_ROOT="$OMARCHY_ZRAM_ROOT" "$generator" "$output"
  [[ ! -e $output/dev-zram0.swap ]] || fail "unconfigured generator produces no swap"
  run_migration 0
  ZRAM_GENERATOR_ROOT="$OMARCHY_ZRAM_ROOT" "$generator" "$output"
  [[ -f $output/dev-zram0.swap ]] || fail "fallback produces a swap unit"
  grep -Fx 'Requires=systemd-zram-setup@zram0.service' "$output/dev-zram0.swap" >/dev/null ||
    fail "generated swap starts the device setup service"
  [[ -L $output/swap.target.wants/dev-zram0.swap ]] || fail "generated swap joins swap.target"
  pass "the real generator creates swap from the repaired configuration"
else
  pass "zram-generator is unavailable; skipping real generator integration"
fi
