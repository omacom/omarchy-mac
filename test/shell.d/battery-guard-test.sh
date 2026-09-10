#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

power_dir="$tmp_dir/power"
state_dir="$tmp_dir/state"
export HOME="$tmp_dir/home"

mkdir -p "$power_dir/BAT0" "$power_dir/AC" "$state_dir" "$HOME"

empty_power_dir="$tmp_dir/empty-power"
empty_state_dir="$tmp_dir/empty-state"
mkdir -p "$empty_power_dir"
OMARCHY_POWER_SUPPLY_PATH="$empty_power_dir" OMARCHY_BATTERY_GUARD_STATE_DIR="$empty_state_dir" \
  OMARCHY_BATTERY_GUARD_MAX_ONESHOT_CYCLES=1 "$ROOT/bin/omarchy-battery-guard" --oneshot
[[ ! -e $empty_state_dir/state ]] || fail "a machine without a battery must not receive periodic state writes"

cat >"$power_dir/BAT0/type" <<'EOF'
Battery
EOF
printf '%s\n' 1 >"$power_dir/BAT0/present"
printf '%s\n' 5 >"$power_dir/BAT0/capacity"
printf '%s\n' Discharging >"$power_dir/BAT0/status"
printf '%s\n' 1000000 >"$power_dir/BAT0/power_now"
printf '%s\n' 5000 >"$power_dir/BAT0/energy_now"

export OMARCHY_POWER_SUPPLY_PATH="$power_dir"
export OMARCHY_BATTERY_GUARD_STATE_DIR="$state_dir"
export OMARCHY_BATTERY_GUARD_COUNTDOWN_SECONDS=2
export OMARCHY_BATTERY_GUARD_POLL_INTERVAL=1
export OMARCHY_BATTERY_GUARD_MAX_ONESHOT_CYCLES=4
export OMARCHY_BATTERY_GUARD_THRESHOLD_PERCENT=10
export OMARCHY_BATTERY_GUARD_DRY_RUN=true

"$ROOT/bin/omarchy-battery-guard" --oneshot

action_file="$state_dir/boot-preserve-required"
[[ -f $action_file ]] || fail "battery guard marks protective action when critical"

grep -F 'mode=' "$state_dir/state" >/dev/null || fail "battery guard writes runtime mode"
grep -F 'percentage=' "$state_dir/state" >/dev/null || fail "battery guard writes battery percentage into state"

printf '%s\n' Mains >"$power_dir/AC/type"
printf '%s\n' 1 >"$power_dir/AC/online"
rm -f "$action_file"

"$ROOT/bin/omarchy-battery-guard" --oneshot
[[ ! -f $action_file ]] || fail "battery guard does not mark action when AC is present"

cat >"$state_dir/state" <<STATE
mode=countdown
percentage=8
remaining=5
updated=1
STATE

"$ROOT/bin/omarchy-battery-guard" --oneshot
grep -Fx 'mode=idle' "$state_dir/state" >/dev/null || fail "battery guard clears pending countdown after plug-in on boot"

printf '%s\n' 0 >"$power_dir/AC/online"
printf '%s\n' 50 >"$power_dir/BAT0/capacity"
rm -f "$power_dir/BAT0/energy_now" "$power_dir/BAT0/power_now" "$action_file"
printf '%s\n' 5000000 >"$power_dir/BAT0/charge_now"
printf '%s\n' 1000 >"$power_dir/BAT0/current_now"
printf '%s\n' 1000000 >"$power_dir/BAT0/voltage_now"

"$ROOT/bin/omarchy-battery-guard" --oneshot
[[ ! -f $action_file ]] || fail "charge and current units do not create a false time-to-empty action"

injected_file="$tmp_dir/state-was-executed"
printf 'mode=$(touch %s)\nremaining=5\n' "$injected_file" >"$state_dir/state"
printf '%s\n' 1 >"$power_dir/AC/online"

"$ROOT/bin/omarchy-battery-guard" --oneshot
[[ ! -e $injected_file ]] || fail "battery guard must treat persisted state as data"

mock_bin="$tmp_dir/mock-bin"
migration_home="$tmp_dir/migration-home"
systemctl_log="$tmp_dir/systemctl.log"
mkdir -p "$mock_bin" "$migration_home"

cat >"$mock_bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"

if [[ $1 == "is-enabled" ]]; then
  [[ ${SYSTEMCTL_ENABLED:-false} == "true" ]]
elif [[ $1 == "is-active" ]]; then
  [[ ${SYSTEMCTL_ACTIVE:-false} == "true" ]]
elif [[ $1 == "hibernate" ]]; then
  [[ ${SYSTEMCTL_HIBERNATE_SUCCESS:-false} == "true" ]]
elif [[ $1 == "poweroff" ]]; then
  exit 1
fi
EOF
chmod +x "$mock_bin/systemctl"

cat >"$mock_bin/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF

cat >"$mock_bin/omarchy-hibernation-available" <<'EOF'
#!/bin/bash
if [[ -n ${PLUG_AC_ON_CHECK:-} ]]; then
  printf '%s\n' 1 >"$PLUG_AC_ON_CHECK"
fi
[[ ${HIBERNATION_AVAILABLE:-false} == "true" ]]
EOF
cat >"$mock_bin/omarchy-hook" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$mock_bin/omarchy-notification-send" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mock_bin/sudo" "$mock_bin/omarchy-hibernation-available" "$mock_bin/omarchy-hook" "$mock_bin/omarchy-notification-send"

printf '%s\n' 0 >"$power_dir/AC/online"
printf '%s\n' 5 >"$power_dir/BAT0/capacity"
rm -f "$state_dir/state" "$action_file"
: >"$systemctl_log"
PATH="$mock_bin:$PATH" SYSTEMCTL_LOG="$systemctl_log" PLUG_AC_ON_CHECK="$power_dir/AC/online" \
  OMARCHY_BATTERY_GUARD_DRY_RUN=false OMARCHY_BATTERY_GUARD_COUNTDOWN_SECONDS=1 \
  OMARCHY_BATTERY_GUARD_MAX_ONESHOT_CYCLES=3 "$ROOT/bin/omarchy-battery-guard" --oneshot
! grep -Fx -- 'poweroff --no-wall' "$systemctl_log" >/dev/null || fail "AC arriving at the action boundary must cancel poweroff"

: >"$systemctl_log"
printf '%s\n' 0 >"$power_dir/AC/online"
rm -f "$state_dir/state" "$action_file"
if PATH="$mock_bin:$PATH" SYSTEMCTL_LOG="$systemctl_log" OMARCHY_BATTERY_GUARD_DRY_RUN=false \
  OMARCHY_BATTERY_GUARD_COUNTDOWN_SECONDS=1 OMARCHY_BATTERY_GUARD_MAX_ONESHOT_CYCLES=3 \
  "$ROOT/bin/omarchy-battery-guard" --oneshot; then
  fail "battery guard must propagate a failed poweroff"
fi
grep -Fx -- 'poweroff --no-wall' "$systemctl_log" >/dev/null || fail "battery guard attempts poweroff directly"

: >"$systemctl_log"
rm -f "$state_dir/state" "$action_file"
PATH="$mock_bin:$PATH" SYSTEMCTL_LOG="$systemctl_log" HIBERNATION_AVAILABLE=true SYSTEMCTL_HIBERNATE_SUCCESS=true \
  OMARCHY_BATTERY_GUARD_DRY_RUN=false OMARCHY_BATTERY_GUARD_COUNTDOWN_SECONDS=1 \
  OMARCHY_BATTERY_GUARD_MAX_ONESHOT_CYCLES=3 "$ROOT/bin/omarchy-battery-guard" --oneshot
grep -Fx -- 'hibernate --no-wall' "$systemctl_log" >/dev/null || fail "battery guard waits for hibernation to return"
! grep -Fx -- 'poweroff --no-wall' "$systemctl_log" >/dev/null || fail "successful hibernation must not fall through to poweroff"
[[ ! -f $action_file ]] || fail "resumed hibernation clears the recovery marker"

HOME="$migration_home" PATH="$mock_bin:$PATH" SYSTEMCTL_LOG="$systemctl_log" \
  bash -euo pipefail "$ROOT/migrations/1789066533.sh" >/dev/null
grep -Fx -- 'link --force /usr/share/omarchy/default/systemd/system/omarchy-battery-guard.service' "$systemctl_log" >/dev/null || fail "migration links the packaged system unit"
grep -Fx -- 'daemon-reload' "$systemctl_log" >/dev/null || fail "migration reloads the system manager"
grep -Fx -- 'enable --now omarchy-battery-guard.service' "$systemctl_log" >/dev/null || fail "migration enables and starts the system guard"

: >"$systemctl_log"
HOME="$migration_home" PATH="$mock_bin:$PATH" SYSTEMCTL_LOG="$systemctl_log" SYSTEMCTL_ENABLED=true SYSTEMCTL_ACTIVE=true \
  bash -euo pipefail "$ROOT/migrations/1789066533.sh" >/dev/null
[[ $(wc -l <"$systemctl_log") == 2 ]] || fail "migration is idempotent once the system guard is running"

pass "battery guard reacts safely in mocked low battery scenarios"
