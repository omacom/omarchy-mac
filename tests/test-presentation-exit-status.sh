#!/bin/bash
# Checks the exit-status contract of the shared presentation wrapper: the status
# of the command it runs must reach both the message and the caller.
#
# A wrapper that always returns 0 turns every failing menu entry into a green
# "Done!", which is how an install failure was reported as a success. These
# checks run anywhere: they evaluate the wrapper's own presentation script with
# stub commands on PATH, so no terminal, no gum and no Apple hardware needed.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/bin/omarchy-launch-floating-terminal-with-presentation"
SHOW_DONE="$ROOT/bin/omarchy-show-done"

pass() { echo "✓ $*"; }
skip() { echo "- $* (skipped)"; }
fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "=== presentation wrapper exit status ==="
echo "Repo: $ROOT"

[[ -f $WRAPPER ]] || fail "the wrapper is missing"
[[ -f $SHOW_DONE ]] || fail "omarchy-show-done is missing"
bash -n "$WRAPPER" || fail "the wrapper does not parse"
bash -n "$SHOW_DONE" || fail "omarchy-show-done does not parse"
pass "both scripts are present and parse"

# The wrapper execs a terminal, so what is under test is the presentation script
# it builds. Take that line from the file and evaluate it exactly as written.
script_line="$(grep -m1 '^presentation_script=' "$WRAPPER")" ||
  fail "no presentation_script assignment in the wrapper"

stub_dir="$(mktemp -d)"
log="$stub_dir/show-done.log"
trap 'rm -rf -- "$stub_dir"' EXIT

printf '#!/bin/bash\nexit 0\n' >"$stub_dir/omarchy-show-logo"
# Records its argument so the test can tell "called with 37" from "called with
# nothing", which is the difference between a real report and the old bug.
{
  echo '#!/bin/bash'
  echo 'printf "%s\n" "${1-<no-argument>}" >>"$SHOW_DONE_LOG"'
} >"$stub_dir/omarchy-show-done"
chmod +x "$stub_dir/omarchy-show-logo" "$stub_dir/omarchy-show-done"

# Runs the wrapper's presentation script with a command that exits $1.
# Echoes the status it returned; the show-done log is left for the caller.
run_case() {
  local code="$1"
  : >"$log"
  printf '#!/bin/bash\nexit %d\n' "$code" >"$stub_dir/fake-cmd"
  chmod +x "$stub_dir/fake-cmd"
  local status=0
  PATH="$stub_dir:$PATH" SHOW_DONE_LOG="$log" cmd="fake-cmd" \
    bash -c "$script_line"'; bash -c "$presentation_script"' >/dev/null 2>&1 || status=$?
  echo "$status"
}

echo
echo "=== the caller gets the command's status ==="

for code in 0 1 2 37; do
  got="$(run_case "$code")"
  [[ $got == "$code" ]] ||
    fail "a command exiting $code left the wrapper returning $got"
  pass "exit $code propagates"
done

echo
echo "=== the message matches the status ==="

run_case 0 >/dev/null
[[ "$(cat "$log")" == "0" ]] ||
  fail "success should call omarchy-show-done with 0, got: $(cat "$log")"
pass "success reports 0 to omarchy-show-done"

run_case 37 >/dev/null
[[ "$(cat "$log")" == "37" ]] ||
  fail "a failure should report its real status, got: $(cat "$log")"
pass "failure reports 37, not an empty or zero status"

echo
echo "=== cancellation ==="

got="$(run_case 130)"
[[ $got == 130 ]] || fail "cancellation should return 130, got $got"
[[ ! -s $log ]] || fail "cancellation should show no message, logged: $(cat "$log")"
pass "130 returns 130 and shows no message"

echo
echo "=== omarchy-show-done argument handling ==="

# The existing callers (omarchy-pkg-install, omarchy-pkg-aur-install,
# omarchy-pkg-remove) pass nothing, so no argument must still mean success.
grep -q 'status="${1:-0}"' "$SHOW_DONE" ||
  fail "omarchy-show-done should default a missing status to 0"
pass "a missing status defaults to 0, keeping the no-argument callers working"

for caller in omarchy-pkg-install omarchy-pkg-aur-install omarchy-pkg-remove; do
  [[ -f "$ROOT/bin/$caller" ]] || continue
  bash -n "$ROOT/bin/$caller" || fail "$caller does not parse"
  pass "$caller still parses against the new signature"
done

if command -v script >/dev/null && command -v timeout >/dev/null; then
  # omarchy-show-done reads the keypress from /dev/tty, so the input has to go
  # to the pty rather than the pipeline. It also drains queued input first, so
  # a key sent immediately gets swallowed and the read then waits forever:
  # hence the delay. timeout keeps a hang from stalling the suite.
  on_tty() {
    (
      sleep 0.4
      printf 'x'
    ) | timeout 10 script -qec "$*" /dev/null 2>/dev/null | tr -d '\r'
  }

  out="$(on_tty "$SHOW_DONE")" || true
  case $out in
    *Done!*) pass "no argument shows the success message on a terminal" ;;
    *) fail "no argument should show Done!, got: $out" ;;
  esac

  out="$(on_tty "$SHOW_DONE 37")" || true
  case $out in
    *"Failed (exit 37)"*) pass "a status of 37 shows a failure message naming it" ;;
    *) fail "status 37 should show Failed (exit 37), got: $out" ;;
  esac

  out="$(on_tty "$SHOW_DONE not-a-number")" || true
  case $out in
    *Failed*) pass "a non-numeric status is treated as a failure, not a success" ;;
    *) fail "a non-numeric status should not claim success, got: $out" ;;
  esac
else
  skip "no script(1) or timeout(1), so the on-terminal messages are not exercised here"
fi

echo
echo "All presentation exit-status checks passed."
