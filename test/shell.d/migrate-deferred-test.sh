#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

test_root="$test_tmp/omarchy"
test_home="$test_tmp/home"
stub_bin="$test_tmp/bin"
state="$test_home/.local/state/omarchy/migrations"
mkdir -p "$test_root/migrations" "$test_home" "$stub_bin"

cat >"$stub_bin/omarchy-notification-dismiss" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >>"$TEST_DISMISSALS"
SH
chmod +x "$stub_bin/omarchy-notification-dismiss"

# Each migration records its run and exits with the status its fixture file holds.
for name in 100 200 300; do
  cat >"$test_root/migrations/$name.sh" <<SH
echo $name >>"\$TEST_CALLS"
exit "\$(cat "\$TEST_STATUS/$name")"
SH
done
mkdir -p "$test_tmp/status"

run_migrate() {
  : >"$test_tmp/calls"
  : >"$test_tmp/dismissals"
  HOME="$test_home" \
  OMARCHY_PATH="$test_root" \
  PATH="$stub_bin:$ROOT/bin:$PATH" \
  TEST_CALLS="$test_tmp/calls" \
  TEST_STATUS="$test_tmp/status" \
  TEST_DISMISSALS="$test_tmp/dismissals" \
    "$ROOT/bin/omarchy-migrate" "$@"
}

set_status() {
  echo "$2" >"$test_tmp/status/$1"
}

set_status 100 75
set_status 200 0
set_status 300 0
run_migrate >"$test_tmp/out" || fail "a deferred migration does not fail omarchy-migrate" "$(cat "$test_tmp/out")"
[[ $(cat "$test_tmp/calls") == $'100\n200\n300' ]] || fail "later migrations run after a deferred one" "$(cat "$test_tmp/calls")"
[[ ! -e $state/100.sh && -e $state/200.sh && -e $state/300.sh ]] || fail "only the deferred migration stays pending"
[[ $(run_migrate --pending) == "100.sh" ]] || fail "omarchy-migrate --pending lists the deferred migration"
[[ ! -s $test_tmp/dismissals ]] || fail "a deferred migration keeps the pending-migrations notification"
grep -q 'Deferred migrations still pending: 100' "$test_tmp/out" || fail "omarchy-migrate names the deferred migration" "$(cat "$test_tmp/out")"
pass "a migration exiting 75 stays pending with its notification while later migrations run"

run_migrate >"$test_tmp/out" || fail "a still-deferred migration does not fail omarchy-migrate"
[[ $(cat "$test_tmp/calls") == "100" ]] || fail "a rerun retries only the deferred migration" "$(cat "$test_tmp/calls")"
set_status 100 0
run_migrate >"$test_tmp/out" || fail "a deferred migration completes on a later run"
[[ -e $state/100.sh ]] || fail "a deferred migration is marked done once it succeeds"
grep -Fx 'Omarchy Migrations' "$test_tmp/dismissals" >/dev/null || fail "the notification clears once nothing is deferred"
pass "a deferred migration is retried on every run and marked done once it succeeds"

rm -rf "$state"
set_status 100 75
set_status 200 3
if run_migrate >"$test_tmp/out" 2>&1; then
  fail "a failing migration still fails omarchy-migrate after a deferred one"
else
  status=$?
fi
(( status == 3 )) || fail "omarchy-migrate exits with the failing migration's status" "status $status"
[[ $(cat "$test_tmp/calls") == $'100\n200' ]] || fail "a failing migration stops the queue" "$(cat "$test_tmp/calls")"
[[ ! -e $state/100.sh && ! -e $state/200.sh && ! -e $state/300.sh ]] || fail "nothing is marked done past a failure"
[[ ! -s $test_tmp/dismissals ]] || fail "a failure keeps the notification"
pass "any status other than 0 and 75 still stops the queue with that status"
