#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
mkdir -p "$tmp_dir/power/BAT0"
printf '900000\n' >"$tmp_dir/power/BAT0/current_now"
printf '12000000\n' >"$tmp_dir/power/BAT0/voltage_now"
printf '312\n' >"$tmp_dir/power/BAT0/cycle_count"
cat >"$tmp_dir/bin/upower" <<'STUB'
#!/bin/bash

if [[ $1 == "-e" ]]; then
  echo "/org/freedesktop/UPower/devices/battery_BAT0"
  exit 0
fi

if [[ $1 == "-i" ]]; then
  cat <<'INFO'
  native-path:          BAT0
  state:                discharging
  energy:               28.3 Wh
  energy-full:          56.7 Wh
  energy-rate:          7.3 W
  time to empty:        2.5 hours
  percentage:           51%
INFO
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/bin/upower"

shell_output=$(OMARCHY_POWER_SUPPLY_PATH="$tmp_dir/power" PATH="$tmp_dir/bin:$PATH" "$ROOT/bin/omarchy-battery-status" --shell)

grep -Fx $'percentage\t49%' <<<"$shell_output" >/dev/null || fail "battery status reports usable percentage"
grep -Fx $'state\tdischarging' <<<"$shell_output" >/dev/null || fail "battery status reports state"
grep -Fx $'rate\t10.8W' <<<"$shell_output" >/dev/null || fail "battery status reports live sysfs power rate"
grep -Fx $'size\t56Wh' <<<"$shell_output" >/dev/null || fail "battery status reports full capacity"
grep -Fx $'time\t2h 30m' <<<"$shell_output" >/dev/null || fail "battery status reports remaining time"
grep -Fx $'cycles\t312' <<<"$shell_output" >/dev/null || fail "battery status reports charge cycles"


# Apple Silicon names the device macsmc-battery, with no uppercase BAT
# anywhere: the old device match found nothing, the command exited 0 without
# output, and the power panel hid every battery reading it had.
asahi_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir" "$asahi_dir"' EXIT

mkdir -p "$asahi_dir/bin" "$asahi_dir/power/macsmc-battery"
printf '1500000\n' >"$asahi_dir/power/macsmc-battery/power_now"
printf '80\n' >"$asahi_dir/power/macsmc-battery/charge_control_end_threshold"
printf '405\n' >"$asahi_dir/power/macsmc-battery/cycle_count"
cat >"$asahi_dir/bin/upower" <<'STUB'
#!/bin/bash

if [[ $1 == "-e" ]]; then
  echo "/org/freedesktop/UPower/devices/line_power_macsmc_ac"
  echo "/org/freedesktop/UPower/devices/battery_macsmc_battery"
  echo "/org/freedesktop/UPower/devices/DisplayDevice"
  exit 0
fi

if [[ $1 == "-i" ]]; then
  cat <<'INFO'
  native-path:          macsmc-battery
  state:                discharging
  energy-full:          69.6 Wh
  energy-rate:          9.9 W
  time to empty:        4.1 hours
  percentage:           88%
INFO
  exit 0
fi

exit 1
STUB
chmod +x "$asahi_dir/bin/upower"

asahi_output=$(OMARCHY_POWER_SUPPLY_PATH="$asahi_dir/power" PATH="$asahi_dir/bin:$PATH" "$ROOT/bin/omarchy-battery-status" --shell)

[[ -n $asahi_output ]] || fail "battery status finds an Apple Silicon battery"
grep -Fx $'percentage\t88%' <<<"$asahi_output" >/dev/null || fail "Apple Silicon percentage is read"
grep -Fx $'size\t69Wh' <<<"$asahi_output" >/dev/null || fail "Apple Silicon capacity is read"
grep -Fx $'rate\t1.5W' <<<"$asahi_output" >/dev/null || fail "Apple Silicon rate comes from its own sysfs"
grep -Fx $'threshold\t80%' <<<"$asahi_output" >/dev/null || fail "Apple Silicon charge threshold is read"
grep -Fx $'cycles\t405' <<<"$asahi_output" >/dev/null || fail "Apple Silicon charge cycles are read"

# Display rounding is half-up to match the bar widget, but the charge-hold
# check must compare UPower's raw percentage: 79.5% displays as 79%, and an
# 80% hold threshold must not trip while the raw value is still below it.
hold_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir" "$asahi_dir" "$hold_dir"' EXIT

mkdir -p "$hold_dir/bin" "$hold_dir/power/macsmc-battery" "$hold_dir/power/ac"
printf 'Mains\n' >"$hold_dir/power/ac/type"
printf '1\n' >"$hold_dir/power/ac/online"
printf '80\n' >"$hold_dir/power/macsmc-battery/charge_control_end_threshold"
cat >"$hold_dir/bin/upower" <<'STUB'
#!/bin/bash

if [[ $1 == "-e" ]]; then
  echo "/org/freedesktop/UPower/devices/battery_macsmc_battery"
  exit 0
fi

if [[ $1 == "-i" ]]; then
  cat <<'INFO'
  native-path:          macsmc-battery
  state:                charging
  energy-full:          69.6 Wh
  energy-rate:          0.1 W
  time to full:         0.2 hours
  percentage:           79.5%
  charge-end-threshold: 80%
INFO
  exit 0
fi

exit 1
STUB
chmod +x "$hold_dir/bin/upower"

hold_output=$(OMARCHY_POWER_SUPPLY_PATH="$hold_dir/power" PATH="$hold_dir/bin:$PATH" "$ROOT/bin/omarchy-battery-status" --shell)

grep -Fx $'percentage\t79%' <<<"$hold_output" >/dev/null || fail "display percentage maps usable charge"
grep -Fx $'state\tcharging' <<<"$hold_output" >/dev/null || fail "hold threshold compares the raw percentage"

pass "battery status reads an Apple Silicon battery"

if matches=$(rg -n 'omarchy-battery-(capacity|remaining|remaining-time)' "$ROOT/bin" "$ROOT/test" "$ROOT/shell" "$ROOT/docs"); then
  fail "battery status owns capacity and remaining calculations" "$matches"
fi

pass "battery status owns capacity and remaining calculations"
