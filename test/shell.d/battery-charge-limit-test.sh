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

cat >"$tmp_dir/bin/pkexec" <<'SH'
#!/bin/bash
[[ $1 == "/usr/bin/tee" ]] || exit 1
[[ ${PKEXEC_FAIL_PATH:-} != "$2" ]] || exit 1
cat >"$2"
SH
chmod +x "$tmp_dir/bin/pkexec"

export PATH="$tmp_dir/bin:$PATH"
test_command="$tmp_dir/bin/omarchy-battery-charge-limit"
sed "s|/sys/class/power_supply/macsmc-battery|$battery_path|" "$ROOT/bin/omarchy-battery-charge-limit" >"$test_command"
chmod +x "$test_command"

status=$("$test_command")
[[ $status == "Charge limit: 100% (restart charging at 100%)" ]] || fail "reports the active limit"
pass "reports the active Apple Silicon charge thresholds"

"$test_command" 80
[[ $(<"$battery_path/charge_control_start_threshold") == 75 ]] || fail "sets the restart threshold to 75%"
[[ $(<"$battery_path/charge_control_end_threshold") == 80 ]] || fail "sets the end threshold to 80%"
pass "sets the 80% cap and five point hysteresis"

"$test_command" 100
[[ $(<"$battery_path/charge_control_start_threshold") == 100 ]] || fail "restores the restart threshold"
[[ $(<"$battery_path/charge_control_end_threshold") == 100 ]] || fail "restores the end threshold"
pass "restores full charging"

if PKEXEC_FAIL_PATH="$battery_path/charge_control_end_threshold" "$test_command" 80 >/dev/null 2>&1; then
  fail "reports a failed threshold update"
fi
[[ $(<"$battery_path/charge_control_start_threshold") == 100 ]] || fail "rolls the restart threshold back after a failed update"
[[ $(<"$battery_path/charge_control_end_threshold") == 100 ]] || fail "preserves the end threshold after a failed update"
pass "rolls back the first threshold if the second update fails"

if "$test_command" 85 >/dev/null 2>&1; then
  fail "rejects unsupported limits"
fi
[[ $(<"$battery_path/charge_control_end_threshold") == 100 ]] || fail "invalid input leaves the limit unchanged"
pass "rejects unsupported limits without changing the device"
