#!/bin/bash

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

failing_script="$work_dir/fail.sh"
log_file="$work_dir/install.log"
console_file="$work_dir/console.log"
unset OMARCHY_LOG_TO_STDOUT
cat >"$failing_script" <<'SCRIPT'
echo "about to fail"
false
SCRIPT

set +e
(
  set -euo pipefail
  export OMARCHY_INSTALL_LOG_FILE="$log_file"
  source "$ROOT/install/helpers/logging.sh"
  run_logged "$failing_script"
  echo "unreachable"
) >"$console_file" 2>&1
status=$?
set -e

(( status == 1 )) || fail "run_logged returns failing script status"
grep -q "Starting: $failing_script" "$log_file" || fail "run_logged logs script start"
grep -q "about to fail" "$log_file" || fail "run_logged captures script output"
grep -q "Failed: $failing_script (exit code: 1)" "$log_file" || fail "run_logged logs failed script before errexit exits"
[[ $(cat "$console_file") == "Error: setup failed in $failing_script (exit code: 1). See $log_file for details." ]] ||
  fail "file logging identifies the failed script, status, and log path on the console"

stdout_log="$work_dir/stdout.log"
set +e
(
  set -euo pipefail
  export OMARCHY_INSTALL_LOG_FILE="$work_dir/iso-owned.log"
  export OMARCHY_LOG_TO_STDOUT=1
  source "$ROOT/install/helpers/logging.sh"
  run_logged "$failing_script"
) >"$stdout_log" 2>&1
stdout_status=$?
set -e

(( stdout_status == 1 )) || fail "stdout run_logged returns failing script status"
[[ ! -e $work_dir/iso-owned.log ]] || fail "stdout logging mode does not write directly to install log"
grep -q "Starting: $failing_script" "$stdout_log" || fail "stdout logging mode emits script start"
grep -q "about to fail" "$stdout_log" || fail "stdout logging mode emits script output"
grep -q "Failed: $failing_script (exit code: 1)" "$stdout_log" || fail "stdout logging mode emits failure marker"
if grep -q 'Error: setup failed' "$stdout_log"; then
  fail "stdout logging mode does not duplicate its failure report"
fi

pass "run_logged records failures under errexit"

# Reproduce the silent exit 127 from a missing setup command without running
# any real system setup. Its shell diagnostic stays in the log, while the
# console identifies the failed leaf and points to the details.
cat >"$failing_script" <<SCRIPT
"$work_dir/missing-setup-command"
echo "unreachable"
SCRIPT

set +e
(
  set -euo pipefail
  export OMARCHY_INSTALL_LOG_FILE="$log_file"
  source "$ROOT/install/helpers/logging.sh"
  run_logged "$failing_script"
  echo "unreachable"
) >"$console_file" 2>&1
status=$?
set -e

(( status == 127 )) || fail "run_logged preserves missing-command status 127"
[[ $(cat "$console_file") == "Error: setup failed in $failing_script (exit code: 127). See $log_file for details." ]] ||
  fail "a missing setup command reports its failed leaf and log path"
grep -qF "$work_dir/missing-setup-command" "$log_file" || fail "the log retains the original shell diagnostic"
if grep -q 'unreachable' "$log_file" "$console_file"; then
  fail "a missing setup command stops both the leaf and setup caller"
fi
pass "a missing setup command is visible on the console and keeps exit 127"

printf 'echo "successful setup output"\n' >"$work_dir/success.sh"
(
  set -euo pipefail
  export OMARCHY_INSTALL_LOG_FILE="$log_file"
  source "$ROOT/install/helpers/logging.sh"
  run_logged "$work_dir/success.sh"
) >"$console_file" 2>&1
[[ ! -s $console_file ]] || fail "successful file logging stays quiet on the console"
grep -qF "Completed: $work_dir/success.sh" "$log_file" || fail "successful setup still records completion"
pass "successful file logging stays quiet"
