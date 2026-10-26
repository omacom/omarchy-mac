#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

lid_close="$ROOT/bin/omarchy-system-lid-close"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

setup_scenario() {
  scenario_dir="$tmpdir/$1"
  mock_bin="$scenario_dir/bin"
  call_log="$scenario_dir/calls"
  runtime_dir="$scenario_dir/runtime"
  mkdir -p "$mock_bin" "$runtime_dir"
  : >"$call_log"

  local closed="$2" docked="$3"

  cat >"$mock_bin/omarchy-hw-laptop-closed" <<SH
#!/bin/bash
exit $closed
SH
  cat >"$mock_bin/omarchy-hw-external-monitors" <<SH
#!/bin/bash
echo omarchy-hw-external-monitors >>"\$CALL_LOG"
exit $docked
SH
  for command in omarchy-system-lock omarchy-hyprland-monitor-clamshell systemctl setsid; do
    cat >"$mock_bin/$command" <<SH
#!/bin/bash
echo $command \$* >>"\$CALL_LOG"
SH
  done
  chmod +x "$mock_bin"/*
}

run_lid() {
  local mode=$1
  CALL_LOG="$call_log" \
    OMARCHY_LID_RUNTIME_DIR="$runtime_dir" \
    OMARCHY_LID_SUSPEND_FOREGROUND=1 \
    OMARCHY_LID_SUSPEND_DELAY=0 \
    PATH="$mock_bin:$PATH" \
    "$lid_close" $mode
  mapfile -t calls <"$call_log"
}

called() {
  local command="$1"
  local line
  for line in "${calls[@]}"; do
    [[ $line == "$command" || $line == "$command "* ]] && return 0
  done
  return 1
}

# logind reports the lid open on the hardware this fixes. The SMC edge is the
# close, so the session still locks and the waiter asks systemctl to suspend.
setup_scenario blind_logind 1 1
run_lid --smc-closed

called omarchy-system-lock ||
  fail "SMC lid close locks when logind still reports the lid open" "calls: ${calls[*]}"
pass "SMC lid close locks when logind still reports the lid open"

called omarchy-hyprland-monitor-clamshell ||
  fail "SMC lid close reconciles displays" "calls: ${calls[*]}"
pass "SMC lid close reconciles displays"

called "systemctl suspend" ||
  fail "SMC lid close suspends when logind missed the switch" "calls: ${calls[*]}"
pass "SMC lid close suspends when logind missed the switch"

# An external display is clamshell mode. Same rule as HandleLidSwitchDocked:
# stay awake, stay unlocked, only reconcile the panels.
setup_scenario docked 1 0
run_lid --smc-closed

called omarchy-system-lock &&
  fail "docked SMC lid close does not lock" "calls: ${calls[*]}"
pass "docked SMC lid close does not lock"

called "systemctl suspend" &&
  fail "docked SMC lid close does not suspend" "calls: ${calls[*]}"
pass "docked SMC lid close does not suspend"

called omarchy-hyprland-monitor-clamshell ||
  fail "docked SMC lid close reconciles displays" "calls: ${calls[*]}"
pass "docked SMC lid close reconciles displays"

# The generic binding keeps consulting logind. A replayed switch while the lid
# is open must not grow a suspend of its own.
setup_scenario generic_open 1 1
run_lid ""

called omarchy-system-lock &&
  fail "generic open lid does not lock" "calls: ${calls[*]}"
pass "generic open lid does not lock"

called "systemctl suspend" &&
  fail "generic lid close does not suspend on its own" "calls: ${calls[*]}"
pass "generic lid close does not suspend on its own"

# Opening the lid drops the token. A waiter that then runs finds nothing to do.
setup_scenario cancelled 1 1
CALL_LOG="$call_log" \
  OMARCHY_LID_RUNTIME_DIR="$runtime_dir" \
  PATH="$mock_bin:$PATH" \
  "$lid_close" --smc-opened
printf '%s\n' "stale-token" >"$runtime_dir/token"
CALL_LOG="$call_log" \
  OMARCHY_LID_RUNTIME_DIR="$runtime_dir" \
  PATH="$mock_bin:$PATH" \
  "$lid_close" --wait "fresh-token" 0
mapfile -t calls <"$call_log"

called "systemctl suspend" &&
  fail "opening the lid cancels a suspend that has not started" "calls: ${calls[*]}"
pass "opening the lid cancels a suspend that has not started"

called omarchy-hyprland-monitor-clamshell ||
  fail "opening the SMC lid reconciles displays" "calls: ${calls[*]}"
pass "opening the SMC lid reconciles displays"

# Suspend freezes the waiter. After thaw, date has jumped and a second
# systemctl suspend would sleep the machine the moment the lid opened.
setup_scenario thawed 1 1
date_state="$scenario_dir/date-ticks"
cat >"$mock_bin/date" <<SH
#!/bin/bash
ticks=0
[[ -f $date_state ]] && ticks=\$(<"$date_state")
ticks=\$((ticks + 1))
printf '%s\n' "\$ticks" >"$date_state"
if (( ticks == 1 )); then
  echo 1000
else
  echo 5000
fi
SH
cat >"$mock_bin/sleep" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$mock_bin/date" "$mock_bin/sleep"
printf '%s\n' "same-token" >"$runtime_dir/token"
: >"$call_log"
CALL_LOG="$call_log" \
  OMARCHY_LID_RUNTIME_DIR="$runtime_dir" \
  PATH="$mock_bin:$PATH" \
  "$lid_close" --wait "same-token" 3
mapfile -t calls <"$call_log"

called "systemctl suspend" &&
  fail "a waiter that thawed after suspend does not suspend again" "calls: ${calls[*]}"
pass "a waiter that thawed after suspend does not suspend again"

# The binding must return without waiting out the delay. setsid is what
# detaches the waiter; the mock records the handoff and does not run it.
setup_scenario detached 1 1
: >"$call_log"
CALL_LOG="$call_log" \
  OMARCHY_LID_RUNTIME_DIR="$runtime_dir" \
  PATH="$mock_bin:$PATH" \
  "$lid_close" --smc-closed
mapfile -t calls <"$call_log"

called "setsid -f" ||
  fail "SMC lid close detaches the suspend waiter" "calls: ${calls[*]}"
pass "SMC lid close detaches the suspend waiter"

called "systemctl suspend" &&
  fail "the detached waiter is not run inside the lid binding" "calls: ${calls[*]}"
pass "the detached waiter is not run inside the lid binding"
