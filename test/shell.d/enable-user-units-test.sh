#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

script="$ROOT/install/user/first-run/enable-user-units.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
mock_bin="$TMPDIR/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/systemctl" <<'SH'
#!/bin/bash
echo "$*" >>"$SYSTEMCTL_LOG"
for failing_unit in ${SYSTEMCTL_FAIL_UNITS:-}; do
  if [[ $* == *"$failing_unit"* ]]; then
    echo "Failed to enable unit: Unit $failing_unit does not exist." >&2
    exit 1
  fi
done
exit 0
SH
chmod +x "$mock_bin/systemctl"

log="$TMPDIR/calls"

# Happy path: reload once, then one enable call per unit.
: >"$log"
SYSTEMCTL_LOG="$log" PATH="$mock_bin:$PATH" bash "$script" ||
  fail "enable-user-units exits 0 when every unit enables"
grep -Fqx -- '--user daemon-reload' "$log" || fail "the script reloads the user manager first"
(( $(grep -c -- '--user enable --now' "$log") >= 7 )) ||
  fail "the script enables each shipped unit with its own systemctl call" "$(cat "$log")"
while read -r enable_call; do
  unit_count=$(grep -oE '[A-Za-z0-9@_-]+\.service' <<<"$enable_call" | wc -l)
  (( unit_count == 1 )) ||
    fail "each enable call names exactly one unit" "$enable_call"
done < <(grep -- '--user enable --now' "$log")
pass "enable-user-units enables units one at a time after a daemon reload"

# One missing unit must not block the others or fail the first-run step:
# a non-zero exit here is what kept first-run replaying at every login on
# 4.0.2 when omarchy-brightness-keyboard-auto.service was never packaged.
: >"$log"
stderr_file="$TMPDIR/stderr"
SYSTEMCTL_LOG="$log" SYSTEMCTL_FAIL_UNITS=omarchy-brightness-keyboard-auto.service \
  PATH="$mock_bin:$PATH" bash "$script" 2>"$stderr_file" ||
  fail "one missing unit does not fail the first-run step" "$(cat "$stderr_file")"
grep -Fq 'could not enable omarchy-brightness-keyboard-auto.service' "$stderr_file" ||
  fail "the failing unit is reported by name" "$(cat "$stderr_file")"
grep -Fq 'bt-agent.service' "$log" || fail "units before the failing one are still enabled"
grep -Fq 'omarchy-crash-watch.service' "$log" ||
  fail "units after the failing one are still enabled" "$(cat "$log")"
pass "a missing unit is reported per unit and never wedges first-run"

# A dead user manager is a different failure: nothing can be enabled at all,
# so the step must fail and let first-run retry at the next login.
: >"$log"
if SYSTEMCTL_LOG="$log" SYSTEMCTL_FAIL_UNITS="daemon-reload" \
  PATH="$mock_bin:$PATH" bash "$script" 2>/dev/null; then
  fail "a failed daemon-reload still fails the step"
fi
pass "a dead user manager still fails the step so first-run retries"
