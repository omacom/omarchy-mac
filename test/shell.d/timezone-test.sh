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
