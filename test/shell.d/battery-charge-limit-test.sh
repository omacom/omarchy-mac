#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

battery_path="$tmp_dir/macsmc-battery"
mkdir -p "$battery_path" "$tmp_dir/bin"
printf '100\n' >"$battery_path/charge_control_start_threshold"
printf '100\n' >"$battery_path/charge_control_end_threshold"

cat >"$tmp_dir/bin/sudo" <<'SH'
#!/bin/bash
[[ $1 == "/usr/bin/tee" && $2 == "$BATTERY_PATH/charge_control_end_threshold" ]] || exit 1
printf 'write\n' >>"$SUDO_LOG"
[[ ${SUDO_FAIL:-} != 1 ]] || exit 1
value=$(cat)
[[ ${SUDO_IGNORE:-} != 1 ]] || exit 0
printf '%s\n' "$value" >"$2"
if [[ $value == 80 ]]; then
  printf '75\n' >"$BATTERY_PATH/charge_control_start_threshold"
else
  printf '100\n' >"$BATTERY_PATH/charge_control_start_threshold"
fi
SH
chmod +x "$tmp_dir/bin/sudo"

export PATH="$tmp_dir/bin:$PATH"
export BATTERY_PATH="$battery_path" SUDO_LOG="$tmp_dir/sudo.log"
test_command="$tmp_dir/bin/omarchy-battery-charge-limit"
# Exercise the terminal sudo path even when the suite runs as root.
sed -e "s|/sys/class/power_supply/macsmc-battery|$battery_path|" \
  -e 's/(( EUID == 0 ))/(( 1 == 0 ))/' \
  "$ROOT/bin/omarchy-battery-charge-limit" >"$test_command"
chmod +x "$test_command"

status=$("$test_command")
[[ $status == "Charge limit: 100% (restart charging at 100%)" ]] || fail "reports the active limit"
pass "reports the active Apple Silicon charge thresholds"
[[ ! -e $SUDO_LOG ]] || fail "status does not request privilege"

"$test_command" 80
[[ $(<"$battery_path/charge_control_start_threshold") == 75 ]] || fail "sets the restart threshold to 75%"
[[ $(<"$battery_path/charge_control_end_threshold") == 80 ]] || fail "sets the end threshold to 80%"
pass "sets the 80% cap and five point hysteresis"

"$test_command" 100
[[ $(<"$battery_path/charge_control_start_threshold") == 100 ]] || fail "restores the restart threshold"
[[ $(<"$battery_path/charge_control_end_threshold") == 100 ]] || fail "restores the end threshold"
pass "restores full charging"

if SUDO_FAIL=1 "$test_command" 80 >/dev/null 2>&1; then
  fail "reports a failed threshold update"
fi
[[ $(<"$battery_path/charge_control_start_threshold") == 100 ]] || fail "preserves the restart threshold after a failed update"
[[ $(<"$battery_path/charge_control_end_threshold") == 100 ]] || fail "preserves the end threshold after a failed update"
pass "reports a failed write without changing either threshold"

if SUDO_IGNORE=1 "$test_command" 80 >/dev/null 2>&1; then
  fail "reports a threshold update that did not stick"
fi
pass "checks the driver readback after a successful write"

if "$test_command" 85 >/dev/null 2>&1; then
  fail "rejects unsupported limits"
fi
[[ $(<"$battery_path/charge_control_end_threshold") == 100 ]] || fail "invalid input leaves the limit unchanged"
[[ $(wc -l <"$SUDO_LOG") == 4 ]] || fail "writes only the end threshold once per change"
pass "rejects unsupported limits without changing the device"
