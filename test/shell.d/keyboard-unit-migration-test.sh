#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin" "$test_tmp/units"
unit=omarchy-brightness-keyboard-auto.service
# Redirect only the package filesystem root; retain all migration control
# flow and real filesystem operations in a disposable HOME.
sed "s|/usr/lib/systemd/user/|$test_tmp/units/|g" \
  "$ROOT/migrations/1789205735.sh" >"$test_tmp/migration.sh"
cat >"$test_tmp/bin/systemctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  '--user show-environment') [[ ${MANAGER:-online} == online ]] ;;
  '--user is-enabled omarchy-brightness-keyboard-auto.service')
    [[ ${FAIL_ACTION:-} != is-enabled ]] || exit 1
    printf '%s\n' "${UNIT_STATE:-disabled}"
    [[ ${UNIT_STATE:-disabled} == enabled ]]
    ;;
  '--user show --property=ActiveState --value graphical-session.target')
    [[ ${FAIL_ACTION:-} != show ]] || exit 1
    printf '%s\n' "${GRAPHICAL_STATE:-active}"
    ;;
  *) [[ $2 != "${FAIL_ACTION:-}" ]] ;;
esac
SH
chmod +x "$test_tmp/bin/systemctl"
export HOME="$test_tmp/home" XDG_CONFIG_HOME="$test_tmp/home/.config"
export XDG_RUNTIME_DIR="$test_tmp/run" CALLS="$test_tmp/calls"
export PATH="$test_tmp/bin:$PATH"
run_migration() { bash -euo pipefail "$test_tmp/migration.sh"; }

if run_migration >"$test_tmp/output" 2>&1; then
  fail "missing package unit leaves the migration pending"
fi
[[ ! -e $CALLS ]] || fail "missing package unit does not touch user services"
pass "missing package unit fails before creating a dangling link"

cp "$ROOT/default/systemd/user/$unit" "$test_tmp/units/$unit"
MANAGER=offline run_migration
wants="$XDG_CONFIG_HOME/systemd/user/graphical-session.target.wants/$unit"
[[ -f $wants ]] || fail "offline repair enables the delivered package unit"
MANAGER=offline run_migration
[[ $(readlink "$wants") == "$test_tmp/units/$unit" ]] || fail "repeated repair preserves its unit link"
ln -sfn "$test_tmp/custom.service" "$wants"
MANAGER=offline run_migration
[[ $(readlink "$wants") == "$test_tmp/custom.service" ]] || fail "offline repair preserves a custom unit link"
pass "offline repair is repeatable and preserves existing links"

: >"$CALLS"
run_migration
[[ $(readlink "$wants") == "$test_tmp/custom.service" ]] || fail "online repair preserves a custom unit link"
[[ ! -s $CALLS ]] || fail "custom unit link prevents online service mutation"
rm "$wants"
printf '# custom unit\n' >"$wants"
run_migration
grep -Fx '# custom unit' "$wants" >/dev/null || fail "online repair preserves a regular custom wants entry"
[[ ! -s $CALLS ]] || fail "custom regular entry prevents online service mutation"
rm "$wants"
ln -s "$test_tmp/units/$unit" "$wants"
pass "online repair preserves custom links and regular wants entries"

for state in masked masked-runtime; do
  : >"$CALLS"
  UNIT_STATE="$state" run_migration
  ! grep -Eq -- '--user (enable|start) ' "$CALLS" || fail "$state service is not enabled or started"
done
pass "persistent and runtime masks preserve user opt-outs without blocking migration"

: >"$CALLS"
run_migration
grep -Fx -- "--user enable $unit" "$CALLS" >/dev/null || fail "online repair enables the unit"
grep -Fx -- "--user start $unit" "$CALLS" >/dev/null || fail "active session starts the unit"
: >"$CALLS"
GRAPHICAL_STATE=inactive run_migration
! grep -q -- '--user start' "$CALLS" || fail "inactive graphical session does not start the unit"
pass "online repair starts the unit only in an active graphical session"

for action in daemon-reload is-enabled enable show start; do
  if FAIL_ACTION="$action" run_migration >"$test_tmp/output" 2>&1; then
    fail "failed $action leaves the migration pending"
  fi
done
pass "reload, enablement inspection, enable, session lookup, and start failures all remain retryable"
