#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export TEST_FS="$test_tmp/fs" TEST_CALLS="$test_tmp/calls"
export OMARCHY_LIMINE_DEFAULT="$test_tmp/limine-default"
export OMARCHY_PATH="$test_tmp/omarchy"
mkdir -p "$test_tmp/bin" "$OMARCHY_PATH/default/limine"
printf 'new menu\n' >"$OMARCHY_PATH/default/limine/limine.conf"
cat >"$test_tmp/bin/omarchy-cmd-missing" <<'SH'
#!/bin/bash
[[ ${TEST_MISSING:-0} == "1" ]]
SH
# Map privileged boot paths into a fixture; never touch the host ESP.
cat >"$test_tmp/bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_CALLS"
command=$1
shift
case $command in
  limine-update) exit "${TEST_REBUILD_STATUS:-0}" ;;
  limine-snapper-sync) exit 0 ;;
  test|rm|mv|cp) ;;
  *) exit 99 ;;
esac
args=()
for arg in "$@"; do
  case $arg in /boot/*) arg="$TEST_FS$arg" ;; esac
  args+=("$arg")
done
exec "$command" "${args[@]}"
SH
chmod +x "$test_tmp/bin/"*
export PATH="$test_tmp/bin:$PATH"
machine_id=$(cat /etc/machine-id)

prepare() {
  rm -rf "$TEST_FS"
  mkdir -p "$TEST_FS$1/EFI/Linux"
  printf 'old menu\n' >"$TEST_FS$1/limine.conf"
  printf 'older backup\n' >"$TEST_FS$1/limine.conf.bak"
  touch "$TEST_FS$1/EFI/Linux/omarchy_linux.efi" "$TEST_FS$1/EFI/Linux/${machine_id}_linux.efi"
  : >"$TEST_CALLS"
}
run() { bash "$ROOT/bin/omarchy-refresh-limine"; }
assert_refreshed() {
  [[ $(cat "$TEST_FS$1/limine.conf") == "new menu" ]] || fail "menu refreshed at $1"
  [[ $(cat "$TEST_FS$1/limine.conf.bak") == "old menu" ]] || fail "prior menu backed up at $1"
  [[ ! -e $TEST_FS$1/EFI/Linux/${machine_id}_linux.efi ]] || fail "legacy UKI removed at $1"
  [[ -e $TEST_FS$1/EFI/Linux/omarchy_linux.efi ]] || fail "current UKI retained at $1"
  [[ $(tail -2 "$TEST_CALLS") == $'limine-update\nlimine-snapper-sync' ]] || fail "rebuild precedes snapshot sync"
}

prepare /boot
run
assert_refreshed /boot
pass "missing defaults use /boot and preserve the prior menu as backup"

for declaration in 'ESP_PATH="/boot/efi"' "ESP_PATH='/boot/efi'" 'ESP_PATH=/boot/efi'; do
  prepare /boot/efi
  printf '%s\n' "$declaration" >"$OMARCHY_LIMINE_DEFAULT"
  run
  assert_refreshed /boot/efi
  ! grep -q '/boot/limine.conf' "$TEST_CALLS" || fail "custom ESP never touches default menu"
done
pass "quoted and unquoted configured ESP paths control menu and UKI operations"

prepare /boot
printf 'ESP_PATH=""\n' >"$OMARCHY_LIMINE_DEFAULT"
run
assert_refreshed /boot
pass "empty ESP setting retains the default boot path"

prepare /boot
TEST_MISSING=1 run
[[ ! -s $TEST_CALLS ]] || fail "missing Limine must not change boot files"
[[ $(cat "$TEST_FS/boot/limine.conf") == "old menu" ]] || fail "missing Limine preserves menu"
pass "systems without Limine skip refresh"

prepare /boot
status=0
TEST_REBUILD_STATUS=42 run || status=$?
(( status == 42 )) || fail "rebuild failure must propagate"
! grep -Fxq limine-snapper-sync "$TEST_CALLS" || fail "snapshot sync must not run after rebuild failure"
pass "failed rebuild stops refresh and propagates its status"

prepare /boot
rm "$TEST_FS/boot/limine.conf"
run || fail "a missing menu must be recreated"
[[ $(cat "$TEST_FS/boot/limine.conf") == "new menu" ]] || fail "missing menu recreated from the template"
[[ $(cat "$TEST_FS/boot/limine.conf.bak") == "older backup" ]] || fail "missing menu keeps the older backup"
grep -Fxq limine-update "$TEST_CALLS" || fail "recreated menu is rebuilt"
pass "missing menu is recreated and rebuilt"

prepare /boot
rm "$TEST_FS/boot/limine.conf.bak"
mkdir -p "$TEST_FS/boot/limine.conf.bak/limine.conf"
if run; then fail "failed menu backup must stop refresh"; fi
! grep -Fxq limine-update "$TEST_CALLS" || fail "failed menu backup must prevent rebuilding"
pass "failed menu backup stops before rebuilding"
