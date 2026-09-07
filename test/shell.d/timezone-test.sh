#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

timezone_menu="$ROOT/bin/omarchy-menu-timezone"
sudoers_file="$ROOT/etc/sudoers.d/omarchy-tzupdate"

grep -F '%wheel ALL=(root) NOPASSWD: /usr/bin/timedatectl ^set-timezone [A-Za-z0-9_+][A-Za-z0-9_+.-]*(/[A-Za-z0-9_+][A-Za-z0-9_+.-]*)*$' "$sudoers_file" >/dev/null ||
  fail "timezone sudoers rule allows passwordless timedatectl timezone changes"

! grep -F 'set-timezone *' "$sudoers_file" >/dev/null ||
  fail "timezone sudoers rule uses a bare wildcard that admits extra arguments like -H and -M"

! grep -F 'tzupdate' "$sudoers_file" >/dev/null ||
  fail "timezone sudoers rule does not grant passwordless tzupdate"

grep -F 'sudo timedatectl set-timezone "$timezone"' "$timezone_menu" >/dev/null ||
  fail "timezone menu uses the passwordless sudoers timedatectl rule"

! grep -F 'pkexec timedatectl set-timezone "$timezone"' "$timezone_menu" >/dev/null ||
  fail "timezone menu does not wrap timedatectl in pkexec"

! grep -F 'pkexec /usr/bin/timedatectl set-timezone "$timezone"' "$timezone_menu" >/dev/null ||
  fail "timezone menu does not wrap timedatectl in pkexec"

! grep -F 'sudo /usr/bin/timedatectl set-timezone "$timezone"' "$timezone_menu" >/dev/null ||
  fail "timezone menu lets sudo resolve timedatectl from its secure path"

! grep -Fx 'timedatectl set-timezone "$timezone"' "$timezone_menu" >/dev/null ||
  fail "timezone menu does not use bare timedatectl, which triggers polkit"

grep -F 'omarchy-shell -q omarchy.clock refresh' "$timezone_menu" >/dev/null ||
  fail "timezone menu refreshes the namespaced clock IPC target"

! grep -F 'omarchy-shell -q Clock refresh' "$timezone_menu" >/dev/null ||
  fail "timezone menu no longer refreshes the retired Clock IPC target"

pass "timezone menu refreshes clock after timezone changes"

first_run_tz="$ROOT/install/user/first-run/timezone.sh"
grep -F -- '--exec omarchy-launch-floating-terminal-with-presentation omarchy-cmd-tzupdate-enhanced' \
  "$first_run_tz" >/dev/null ||
  fail "first-run timezone toast passes --exec as separate words"
! grep -F -- '--exec "' "$first_run_tz" >/dev/null ||
  fail "first-run timezone toast does not quote --exec as one string"
pass "first-run timezone toast matches notification-send --exec argv"

# Exercise the actual notification parser, replacing only its D-Bus transport.
require_command jq
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin" "$test_tmp/home"
cat >"$test_tmp/bin/timedatectl" <<'STUB'
#!/bin/bash
printf '%s\n' "$OMARCHY_TEST_TIMEZONE"
STUB
cat >"$test_tmp/bin/busctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$OMARCHY_TEST_NOTIFICATION_ARGS"
STUB
chmod +x "$test_tmp/bin/"*
notification_args="$test_tmp/notification-args"
run_timezone() {
  HOME="$test_tmp/home" PATH="$test_tmp/bin:$ROOT/bin:$PATH" \
    OMARCHY_PATH="$ROOT" OMARCHY_TEST_TIMEZONE="$1" \
    OMARCHY_TEST_NOTIFICATION_ARGS="$notification_args" \
    bash -euo pipefail "$first_run_tz"
}

for zone in UTC ""; do
  run_timezone "$zone" || fail "unset timezone notification is accepted"
  grep -Fx '["omarchy-launch-floating-terminal-with-presentation","omarchy-cmd-tzupdate-enhanced"]' \
    "$notification_args" >/dev/null ||
    fail "timezone notification carries separate executable and argument"
done
pass "unset timezone sends an actionable notification through the real parser"

rm "$notification_args"
run_timezone Europe/London
[[ ! -e $notification_args ]] || fail "configured timezone sends no notification"
pass "configured timezone sends no notification"
