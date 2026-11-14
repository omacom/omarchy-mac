#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1794628107.sh"
manual=https://omarchy.org/manual/mac-support/
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
notify_log="$test_tmp/notify.log"
browser_log="$test_tmp/browser.log"
mkdir -p "$mock_bin"

cat >"$mock_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >>"$OMARCHY_TEST_NOTIFY_LOG"
exit "${OMARCHY_TEST_NOTIFY_STATUS:-0}"
SH

cat >"$mock_bin/omarchy-launch-browser" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_BROWSER_LOG"
SH

chmod +x "$mock_bin"/*

# The way omarchy-migrate runs a migration.
run_migration() {
  : >"$notify_log"
  : >"$browser_log"
  OMARCHY_TEST_NOTIFY_STATUS="$1" \
    OMARCHY_TEST_NOTIFY_LOG="$notify_log" \
    OMARCHY_TEST_BROWSER_LOG="$browser_log" \
    OMARCHY_PATH="$ROOT" \
    PATH="$mock_bin:$PATH" \
    bash -euo pipefail "$migration" >"$test_tmp/out" 2>&1
}

run_migration 0 || fail "the migration succeeds" "$(cat "$test_tmp/out")"
mapfile -t argv <"$notify_log"
(( ${#argv[@]} >= 7 )) || fail "the migration sends one notification" "$(cat "$notify_log")"
[[ ${argv[*]:0:4} == "-u critical -t 0" ]] ||
  fail "the notice is critical and stays until dismissed" "$(cat "$notify_log")"
[[ -n ${argv[4]} ]] || fail "the notice has a summary" "$(cat "$notify_log")"
n=${#argv[@]}
[[ ${argv[*]:n-3} == "--exec omarchy-launch-browser $manual" ]] ||
  fail "clicking the notice opens the Mac manual" "$(cat "$notify_log")"
(( $(grep -cx -- '-u' "$notify_log") == 1 )) || fail "the migration notifies once" "$(cat "$notify_log")"
[[ ! -s $browser_log ]] || fail "the migration does not open a browser by itself" "$(cat "$browser_log")"
grep -qF "$manual" "$test_tmp/out" || fail "the migration prints the Mac manual" "$(cat "$test_tmp/out")"
pass "the migration sends a lasting notice that opens the Mac manual"

run_migration 1 || fail "a failed notification does not fail the update" "$(cat "$test_tmp/out")"
[[ -s $notify_log ]] || fail "the failing notifier was still called"
pass "a failed notification does not fail the update"
