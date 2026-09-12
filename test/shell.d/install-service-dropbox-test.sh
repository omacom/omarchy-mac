#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
state_dir="$test_tmp/state"
calls="$test_tmp/calls"
mkdir -p "$mock_bin" "$state_dir"

cat >"$mock_bin/uname" <<'SCRIPT'
#!/bin/bash
if [[ ${1:-} == "-m" ]]; then
  printf '%s\n' "${OMARCHY_TEST_ARCH:-x86_64}"
else
  exec /usr/bin/uname "$@"
fi
SCRIPT

cat >"$mock_bin/omarchy-pkg-add" <<'SCRIPT'
#!/bin/bash
printf 'pkg-add\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
if [[ ${OMARCHY_TEST_OPTIONAL_WARNING:-0} == 1 ]]; then
  printf '%s\n' "warning: optional Dropbox integration package unavailable; continuing" >&2
fi
exit "${OMARCHY_TEST_PKG_STATUS:-0}"
SCRIPT

cat >"$mock_bin/omarchy-pkg-present" <<'SCRIPT'
#!/bin/bash
printf 'pkg-present\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
[[ $* == "dropbox dropbox-cli" ]] || exit 2
has_dropbox=0
has_dropbox_cli=0
case ${OMARCHY_TEST_PACKAGES:-none} in
  core) has_dropbox=1; has_dropbox_cli=1 ;;
  dropbox-only) has_dropbox=1 ;;
  dropbox-cli-only) has_dropbox_cli=1 ;;
esac
[[ $has_dropbox == 1 && $has_dropbox_cli == 1 ]]
SCRIPT

cat >"$mock_bin/omarchy-cmd-present" <<'SCRIPT'
#!/bin/bash
printf 'cmd-present\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
[[ $* == "dropbox-cli uwsm-app" && ${OMARCHY_TEST_COMMANDS:-none} == "core" ]]
SCRIPT

cat >"$mock_bin/omarchy-plugin-enable" <<'SCRIPT'
#!/bin/bash
printf 'plugin-enable\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
if [[ ${OMARCHY_TEST_PLUGIN_ENABLE_STATUS:-0} != 0 ]]; then
  exit "$OMARCHY_TEST_PLUGIN_ENABLE_STATUS"
fi
printf '%s\n' "${OMARCHY_TEST_PLUGIN_STATE_AFTER_ENABLE:-enabled}" >"$OMARCHY_TEST_PLUGIN_STATE_FILE"
SCRIPT

cat >"$mock_bin/omarchy-plugin-list" <<'SCRIPT'
#!/bin/bash
printf 'plugin-list\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
if [[ ${OMARCHY_TEST_PLUGIN_LIST_STATUS:-0} != 0 ]]; then
  exit "$OMARCHY_TEST_PLUGIN_LIST_STATUS"
fi
if [[ ${1:-} != "--json" ]]; then
  exit 2
fi
state=$(<"$OMARCHY_TEST_PLUGIN_STATE_FILE")
if [[ $state == "malformed" ]]; then
  printf '%s\n' '{not-json'
elif [[ $state == "enabled" ]]; then
  printf '[{"id":"omarchy.dropbox","enabled":true}]\n'
else
  printf '[{"id":"omarchy.dropbox","enabled":false}]\n'
fi
SCRIPT

cat >"$mock_bin/uwsm-app" <<'SCRIPT'
#!/bin/bash
printf 'launch\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
exit "${OMARCHY_TEST_LAUNCH_STATUS:-0}"
SCRIPT

chmod +x "$mock_bin"/*

export PATH="$mock_bin:$ROOT/bin:$PATH"
export OMARCHY_TEST_CALLS="$calls"
export OMARCHY_TEST_PLUGIN_STATE_FILE="$state_dir/plugin-state"
export OMARCHY_TEST_ARCH OMARCHY_TEST_PKG_STATUS OMARCHY_TEST_PACKAGES
export OMARCHY_TEST_COMMANDS OMARCHY_TEST_PLUGIN_ENABLE_STATUS
export OMARCHY_TEST_PLUGIN_LIST_STATUS OMARCHY_TEST_PLUGIN_STATE_AFTER_ENABLE
export OMARCHY_TEST_LAUNCH_STATUS OMARCHY_TEST_OPTIONAL_WARNING

reset_case() {
  : >"$calls"
  printf '%s\n' "disabled" >"$OMARCHY_TEST_PLUGIN_STATE_FILE"
  unset OMARCHY_TEST_ARCH OMARCHY_TEST_PKG_STATUS OMARCHY_TEST_PACKAGES
  unset OMARCHY_TEST_COMMANDS OMARCHY_TEST_PLUGIN_ENABLE_STATUS
  unset OMARCHY_TEST_PLUGIN_LIST_STATUS OMARCHY_TEST_PLUGIN_STATE_AFTER_ENABLE
  unset OMARCHY_TEST_LAUNCH_STATUS OMARCHY_TEST_OPTIONAL_WARNING
  export OMARCHY_TEST_ARCH OMARCHY_TEST_PKG_STATUS OMARCHY_TEST_PACKAGES
  export OMARCHY_TEST_COMMANDS OMARCHY_TEST_PLUGIN_ENABLE_STATUS
  export OMARCHY_TEST_PLUGIN_LIST_STATUS OMARCHY_TEST_PLUGIN_STATE_AFTER_ENABLE
  export OMARCHY_TEST_LAUNCH_STATUS OMARCHY_TEST_OPTIONAL_WARNING
}

run_installer() {
  bash "$1"
}

assert_no_late_mutation() {
  ! grep -Eq '^(plugin-enable|plugin-list|launch)\t' "$calls" ||
    fail "pre-enable failure leaves plugin and launch untouched" "$(cat "$calls")"
}

assert_no_launch() {
  ! grep -Eq '^launch\t' "$calls" || fail "failed Dropbox setup does not request launch" "$(cat "$calls")"
}

wait_for_launch() {
  local expected_count="$1"

  for ((attempt = 0; attempt < 100; attempt++)); do
    launch_count=$(grep -Fc $'launch\t-- dropbox-cli start' "$calls" || true)
    [[ $launch_count == "$expected_count" ]] && return 0
    sleep 0.01
  done
  return 1
}

reset_case
cp "$calls" "$test_tmp/arm-calls-before"
cp "$OMARCHY_TEST_PLUGIN_STATE_FILE" "$test_tmp/arm-state-before"
set +e
OMARCHY_TEST_ARCH=aarch64 run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/arm.out" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "aarch64 Dropbox installation fails closed"
grep -Fq 'unavailable on aarch64' "$test_tmp/arm.out" || fail "aarch64 failure explains unsupported architecture"
assert_no_late_mutation
! grep -Fq $'pkg-add\t' "$calls" || fail "aarch64 does not request packages"
cmp -s "$test_tmp/arm-calls-before" "$calls" || fail "aarch64 preserves call state byte-for-byte"
cmp -s "$test_tmp/arm-state-before" "$OMARCHY_TEST_PLUGIN_STATE_FILE" ||
  fail "aarch64 preserves plugin state byte-for-byte"
pass "aarch64 fails before package, plugin, or launch mutation"

reset_case
OMARCHY_TEST_PKG_STATUS=1
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/pkg-failure.out" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "package helper failure returns nonzero"
assert_no_late_mutation
assert_no_launch
pass "package helper failure stops before plugin enablement"

reset_case
OMARCHY_TEST_PACKAGES=none OMARCHY_TEST_COMMANDS=core
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/pkg-false-success.out" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "package helper false success fails core package gate"
assert_no_late_mutation
assert_no_launch
pass "package helper false success fails before plugin enablement"

reset_case
OMARCHY_TEST_PACKAGES=partial OMARCHY_TEST_COMMANDS=core
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >/dev/null 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "partial core package state fails"
assert_no_late_mutation
pass "partial core package state fails closed"

reset_case
OMARCHY_TEST_PACKAGES=dropbox-only OMARCHY_TEST_COMMANDS=core
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >/dev/null 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "missing dropbox-cli package fails"
assert_no_late_mutation
pass "dropbox present with dropbox-cli missing fails core package gate"

reset_case
OMARCHY_TEST_PACKAGES=dropbox-cli-only OMARCHY_TEST_COMMANDS=core
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >/dev/null 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "missing dropbox package fails"
assert_no_late_mutation
pass "dropbox-cli present with dropbox missing fails core package gate"

reset_case
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=none
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/cmd-failure.out" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "missing core commands fail"
assert_no_late_mutation
assert_no_launch
pass "missing core commands fail before plugin enablement"

reset_case
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=core OMARCHY_TEST_PLUGIN_ENABLE_STATUS=1
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/plugin-failure.out" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "plugin enable failure returns nonzero"
assert_no_launch
pass "plugin enable failure stops before launch"

reset_case
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=core OMARCHY_TEST_PLUGIN_LIST_STATUS=1
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/plugin-list-failure.out" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "plugin list failure returns nonzero"
grep -Fq 'partial state' "$test_tmp/plugin-list-failure.out" || fail "plugin list failure reports partial state"
grep -Fq 'Retry installation or remove the plugin manually' "$test_tmp/plugin-list-failure.out" || fail "plugin list failure reports recovery"
assert_no_launch
grep -Fq 'enabled' "$OMARCHY_TEST_PLUGIN_STATE_FILE" || fail "plugin list failure leaves enabled state visible"
pass "plugin list failure reports partial state without rollback or launch"

reset_case
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=core OMARCHY_TEST_PLUGIN_STATE_AFTER_ENABLE=malformed
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/plugin-malformed.out" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "malformed plugin JSON returns nonzero"
grep -Fq 'partial state' "$test_tmp/plugin-malformed.out" || fail "malformed plugin JSON reports partial state"
assert_no_launch
pass "malformed plugin JSON fails without launch and reports recovery"

reset_case
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=core OMARCHY_TEST_PLUGIN_STATE_AFTER_ENABLE=disabled
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/plugin-disabled.out" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "disabled plugin state fails"
grep -Fq 'not enabled' "$test_tmp/plugin-disabled.out" || fail "disabled plugin state explains verification failure"
assert_no_launch
pass "disabled plugin state fails without launch"

reset_case
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=core
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/success.out" 2>&1
grep -Fq $'pkg-add\tdropbox dropbox-cli libappindicator-gtk3 python-gpgme nautilus-dropbox' "$calls" ||
  fail "success requests core and optional Dropbox packages"
grep -Fq $'pkg-present\tdropbox dropbox-cli' "$calls" || fail "success verifies core packages"
grep -Fq $'cmd-present\tdropbox-cli uwsm-app' "$calls" || fail "success verifies core commands"
grep -Fq 'Dropbox launch requested' "$test_tmp/success.out" || fail "success says launch was requested"
! grep -Eiq 'starting|started|healthy|authenticated' "$test_tmp/success.out" ||
  fail "success does not claim runtime health or authentication" "$(cat "$test_tmp/success.out")"
wait_for_launch 1 || fail "success queues the Dropbox launch" "$(cat "$calls")"
pass "core packages, commands, plugin state, and launch request succeed"

reset_case
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=core OMARCHY_TEST_OPTIONAL_WARNING=1
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >"$test_tmp/optional-warning.out" 2>&1
grep -Fq 'optional Dropbox integration package unavailable; continuing' "$test_tmp/optional-warning.out" ||
  fail "optional integration warning is visible"
wait_for_launch 1 || fail "optional integration skip still queues launch" "$(cat "$calls")"
pass "optional integration warning does not block valid core installation"

reset_case
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=core
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >/dev/null 2>&1
wait_for_launch 1 || fail "first rerun setup queues launch" "$(cat "$calls")"
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >/dev/null 2>&1
[[ $(grep -Fc $'plugin-enable\tomarchy.dropbox' "$calls") == 2 ]] || fail "rerun repeats idempotent plugin enablement"
wait_for_launch 2 || fail "rerun queues launch request" "$(cat "$calls")"
[[ $(grep -Fc $'launch\t-- dropbox-cli start' "$calls") == 2 ]] || fail "rerun repeats launch request"
pass "successful installation is rerunnable"

reset_case
printf '%s\n' "enabled" >"$OMARCHY_TEST_PLUGIN_STATE_FILE"
OMARCHY_TEST_PKG_STATUS=1
set +e
run_installer "$ROOT/bin/omarchy-install-service-dropbox" >/dev/null 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "pre-enable failure remains fatal with existing plugin state"
grep -Fxq 'enabled' "$OMARCHY_TEST_PLUGIN_STATE_FILE" || fail "pre-enable failure preserves existing plugin state"
pass "pre-enable failure preserves existing plugin state"

make_mutation() {
  local name="$1" expression="$2"
  local target="$test_tmp/$name"
  cp "$ROOT/bin/omarchy-install-service-dropbox" "$target"
  perl -0pi -e "$expression" "$target"
  chmod +x "$target"
  printf '%s\n' "$target"
}

reset_case
mutated=$(make_mutation arch-mutation 's/== "aarch64"/!= "aarch64"/')
OMARCHY_TEST_ARCH=aarch64 OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=core
if run_installer "$mutated" >/dev/null 2>&1; then
  wait_for_launch 1 || fail "architecture mutation queues its forbidden launch" "$(cat "$calls")"
  pass "architecture gate mutation is detected"
else
  fail "architecture gate mutation did not bypass the gate"
fi

reset_case
mutated=$(make_mutation core-mutation 's/omarchy-pkg-present dropbox dropbox-cli/:/')
OMARCHY_TEST_PACKAGES=none OMARCHY_TEST_COMMANDS=core
if run_installer "$mutated" >/dev/null 2>&1; then
  wait_for_launch 1 || fail "core package mutation queues its forbidden launch" "$(cat "$calls")"
  pass "core package gate mutation is detected"
else
  fail "core package gate mutation did not bypass the gate"
fi

reset_case
mutated=$(make_mutation command-mutation 's/omarchy-cmd-present dropbox-cli uwsm-app/:/')
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=none
if run_installer "$mutated" >/dev/null 2>&1; then
  wait_for_launch 1 || fail "core command mutation queues its forbidden launch" "$(cat "$calls")"
  pass "core command gate mutation is detected"
else
  fail "core command gate mutation did not bypass the gate"
fi

reset_case
mutated=$(make_mutation plugin-state-mutation 's/if ! jq -e.*/if false; then/')
OMARCHY_TEST_PACKAGES=core OMARCHY_TEST_COMMANDS=core OMARCHY_TEST_PLUGIN_STATE_AFTER_ENABLE=disabled
if run_installer "$mutated" >/dev/null 2>&1; then
  wait_for_launch 1 || fail "plugin state mutation queues its forbidden launch" "$(cat "$calls")"
  pass "plugin state gate mutation is detected"
else
  fail "plugin state gate mutation did not bypass the gate"
fi
