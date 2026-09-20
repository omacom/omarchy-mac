#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"
export TEST_RESTART_CALLS="$test_tmp/calls"
export TEST_KERNEL_BEFORE="$test_tmp/kernel-before"

# Intercept the legacy /tmp filename before the script can read or remove it.
# Every fixture file, including the kernel-version scratch file, stays on disk.
cat >"$mock_bin/cat" <<'SH'
#!/bin/bash
if [[ $* == /tmp/omarchy-kernel-before ]]; then
  exec /usr/bin/cat "$TEST_KERNEL_BEFORE"
fi
exec /usr/bin/cat "$@"
SH
cat >"$mock_bin/rm" <<'SH'
#!/bin/bash
if [[ $* == '-f /tmp/omarchy-kernel-before' ]]; then
  exec /usr/bin/rm -f "$TEST_KERNEL_BEFORE"
fi
exec /usr/bin/rm "$@"
SH
cat >"$mock_bin/find" <<'SH'
#!/bin/bash
if [[ $1 == /usr/lib/modules ]]; then
  [[ ${TEST_RESTART_REASON:-} != modules ]] || echo '/usr/lib/modules/fixture/vmlinuz'
  exit 0
fi
exec /usr/bin/find "$@"
SH
cat >"$mock_bin/readlink" <<'SH'
#!/bin/bash
[[ $* == /proc/123/exe ]] || exit 1
if [[ ${TEST_RESTART_REASON:-} == hyprland ]]; then
  echo '/usr/bin/Hyprland (deleted)'
else
  echo '/usr/bin/Hyprland'
fi
SH
printf '#!/bin/bash\necho 123\n' >"$mock_bin/pgrep"
printf '#!/bin/bash\necho "linux-asahi 2"\n' >"$mock_bin/pacman"
printf '#!/bin/bash\necho "2026-09-13 00:00:00"\n' >"$mock_bin/uptime"
cat >"$mock_bin/gum" <<'SH'
#!/bin/bash
echo "gum $*" >>"$TEST_RESTART_CALLS"
exit "${TEST_CONFIRM_STATUS:-1}"
SH
for command in sudo omarchy-system-reboot omarchy-restart-shell omarchy-restart-audio; do
  cat >"$mock_bin/$command" <<'SH'
#!/bin/bash
echo "${0##*/} $*" >>"$TEST_RESTART_CALLS"
SH
done
chmod +x "$mock_bin/"*

run_restart() {
  local mode="$1" reason="$2"
  task_home="$test_tmp/$mode-$reason-${TEST_CONFIRM_STATUS:-1}"
  state="$task_home/.local/state/omarchy"
  mkdir -p "$state"
  : >"$TEST_RESTART_CALLS"
  : >"$TEST_KERNEL_BEFORE"
  case "$reason" in
    package) echo 1 >"$TEST_KERNEL_BEFORE" ;;
    marker) touch "$state/reboot-required" ;;
  esac
  touch "$state/restart-audio-required"
  HOME="$task_home" PATH="$mock_bin:$ROOT/bin:$PATH" TEST_RESTART_REASON="$reason" \
    OMARCHY_UPDATE_UNATTENDED="$mode" bash "$ROOT/bin/omarchy-update-restart" >"$test_tmp/output" 2>&1
}

for reason in package modules marker hyprland; do
  run_restart 1 "$reason"
  ! grep -Eq '^(gum|sudo|omarchy-system-reboot) ' "$TEST_RESTART_CALLS" || fail "unattended $reason neither prompts nor reboots" "$(cat "$TEST_RESTART_CALLS")"
  [[ -f $state/reboot-required ]] || fail "unattended $reason keeps a reboot reminder"
  [[ ! -f $state/restart-audio-required ]] || fail "unattended $reason handles service restart markers"
  grep -q '^omarchy-restart-audio ' "$TEST_RESTART_CALLS" || fail "unattended $reason still restarts requested services"
  grep -q '^omarchy-restart-shell ' "$TEST_RESTART_CALLS" || fail "unattended $reason still restarts the shell"
done
pass "all unattended reboot conditions defer without prompts and preserve the reminder"

for reason in package modules marker hyprland; do
  run_restart 0 "$reason"
  grep -q '^gum confirm ' "$TEST_RESTART_CALLS" || fail "interactive $reason still asks before rebooting"
  ! grep -Eq '^(sudo|omarchy-system-reboot) ' "$TEST_RESTART_CALLS" || fail "declining $reason does not reboot"
done
pass "interactive reboot prompts remain available and declining never reboots"

TEST_CONFIRM_STATUS=0 run_restart 0 package
grep -q '^sudo reboot now$' "$TEST_RESTART_CALLS" || fail "confirmed Asahi kernel update preserves the reboot path"
TEST_CONFIRM_STATUS=0 run_restart 0 marker
grep -q '^omarchy-system-reboot ' "$TEST_RESTART_CALLS" || fail "confirmed reboot marker preserves the reboot path"
pass "interactive confirmation still reaches the existing reboot commands"

run_restart 1 none
[[ ! -f $state/reboot-required ]] || fail "ordinary unattended updates do not invent a reboot requirement"
! grep -Eq '^(gum|sudo|omarchy-system-reboot) ' "$TEST_RESTART_CALLS" || fail "ordinary unattended updates neither prompt nor reboot"
pass "updates without reboot conditions leave no reboot reminder"
