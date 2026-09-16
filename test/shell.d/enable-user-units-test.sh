#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

script="$ROOT/install/user/first-run/enable-user-units.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/bin"

# The mock reports the enable status and the LoadState separately so a
# transient failure of a unit that is installed is distinguishable from the
# packaging omission the helper is allowed to tolerate.
cat >"$TMPDIR/bin/systemctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$2" in
  daemon-reload) exit "${RELOAD_STATUS:-0}" ;;
  enable)
    if [[ $4 == "${FAIL_UNIT:-}" ]]; then
      echo "Synthetic enable failure: $4" >&2
      exit 42
    fi
    ;;
  show)
    # ${LOAD_STATE-loaded}, not :-, so an explicitly empty state stays empty
    # and the empty-query case is not silently a duplicate of the transient one.
    printf '%s\n' "${LOAD_STATE-loaded}"
    exit "${SHOW_STATUS:-0}"
    ;;
  *) exit 99 ;;
esac
SH
chmod +x "$TMPDIR/bin/systemctl"

run_case() {
  local name="$1" expected="$2" failed="$3" state="$4" show="$5" reload="$6"
  local status=0
  : >"$TMPDIR/calls"
  SYSTEMCTL_LOG="$TMPDIR/calls" FAIL_UNIT="$failed" LOAD_STATE="$state" \
    SHOW_STATUS="$show" RELOAD_STATUS="$reload" PATH="$TMPDIR/bin:$PATH" \
    bash "$script" >"$TMPDIR/out" 2>"$TMPDIR/err" || status=$?
  if [[ $expected == "success" ]]; then
    (( status == 0 )) || fail "$name" "$(cat "$TMPDIR/err")"
  else
    (( status != 0 )) || fail "$name must fail"
  fi
  if (( reload == 0 )); then
    (( $(grep -c -- '^--user enable --now ' "$TMPDIR/calls") == 7 )) ||
      fail "$name must attempt all seven units"
    grep -Fxq -- '--user enable --now omarchy-brightness-keyboard-auto.service' "$TMPDIR/calls" ||
      fail "$name must reach the final unit"
  else
    if grep -q -- 'enable --now' "$TMPDIR/calls"; then
      fail "reload failure must stop before enables"
    fi
  fi
  if [[ -n $failed ]] && (( reload == 0 )); then
    grep -Fq "$failed" "$TMPDIR/err" || fail "$name must identify the failure"
  fi
  pass "$name"
}

run_case happy success '' loaded 0 0
run_case known-missing success omarchy-brightness-keyboard-auto.service not-found 0 0
run_case brightness-transient failure omarchy-brightness-keyboard-auto.service loaded 0 0
run_case brightness-masked failure omarchy-brightness-keyboard-auto.service masked 0 0
run_case brightness-bad-setting failure omarchy-brightness-keyboard-auto.service bad-setting 0 0
run_case brightness-query-failed failure omarchy-brightness-keyboard-auto.service not-found 1 0
run_case brightness-query-empty failure omarchy-brightness-keyboard-auto.service '' 0 0
run_case sleep-transient failure omarchy-sleep-lock.service loaded 0 0
run_case notify-transient failure omarchy-migrate-notify.service loaded 0 0
run_case unrelated-missing failure omarchy-sleep-lock.service not-found 0 0
run_case reload-failed failure '' loaded 0 1
