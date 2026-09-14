#!/bin/bash

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin" "$test_tmp/home"

cat >"$mock_bin/omarchy-done" <<'SH'
#!/bin/bash
[[ $1 == "check" && $2 == "first-run-user" ]]
SH
cat >"$mock_bin/omarchy-provision-user" <<'SH'
#!/bin/bash
touch "$OMARCHY_TEST_FINALIZE_CALLED"
SH
chmod +x "$mock_bin/omarchy-done" "$mock_bin/omarchy-provision-user"

finalize_called="$test_tmp/finalize-called"
HOME="$test_tmp/home" PATH="$mock_bin:$PATH" OMARCHY_TEST_FINALIZE_CALLED="$finalize_called" \
  bash "$ROOT/bin/omarchy-provision-first-run" >"$test_tmp/output"

[[ ! -e $finalize_called ]] || fail "completed first-run exits before any setup step"
grep -F 'First-run already complete' "$test_tmp/output" >/dev/null || fail "completed first-run reports its lifecycle gate"

if grep -F 'user-migration-notify-watch-enabled' "$ROOT/bin/omarchy-provision-first-run" >/dev/null; then
  fail "first-run does not track the migration watcher separately"
fi
if grep -F 'skip-first-run-update-notification' "$ROOT/install/user/first-run/wifi.sh" >/dev/null; then
  fail "first-run does not track update notifications separately"
fi

pass "first-run uses one lifecycle completion marker"

# A failed finalization must keep first-run retryable. The old driver discarded
# this status with "|| true", then marked first-run complete if its later steps
# happened to succeed; a transient setup failure could therefore permanently
# skip the user's required finalization.
retry_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp" "$retry_tmp"' EXIT
retry_bin="$retry_tmp/bin"
retry_root="$retry_tmp/omarchy"
mkdir -p "$retry_bin" "$retry_root/install/user/first-run" "$retry_tmp/home"

cat >"$retry_bin/omarchy-done" <<'SH'
#!/bin/bash
case "$1:$2" in
  check:first-run-user) exit 1 ;;
  mark:first-run-user) touch "$OMARCHY_TEST_FIRST_RUN_MARKER" ;;
esac
SH
cat >"$retry_bin/omarchy-provision-user" <<'SH'
#!/bin/bash
touch "$OMARCHY_TEST_FINALIZE_CALLED"
exit 42
SH
cat >"$retry_bin/omarchy-hook-install" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$retry_bin/omarchy-notification-wait" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$retry_bin"/*

for leaf in \
  welcome.sh timezone.sh wifi.sh enable-user-units.sh gnome-theme.sh \
  gtk-primary-paste.sh audio-tuning.sh; do
  printf '#!/bin/bash\nexit 0\n' >"$retry_root/install/user/first-run/$leaf"
done

retry_marker="$retry_tmp/first-run-marker"
retry_finalize="$retry_tmp/finalize-called"
HOME="$retry_tmp/home" PATH="$retry_bin:$PATH" OMARCHY_PATH="$retry_root" \
  OMARCHY_TEST_FIRST_RUN_MARKER="$retry_marker" \
  OMARCHY_TEST_FINALIZE_CALLED="$retry_finalize" \
  bash "$ROOT/bin/omarchy-provision-first-run" >"$retry_tmp/output"

[[ -e $retry_finalize ]] || fail "first-run attempts user finalization"
[[ ! -e $retry_marker ]] || fail "failed user finalization keeps first-run retryable"
grep -F 'Failed: finalize user (exit code: 42)' \
  "$retry_tmp/home/.local/state/omarchy/first-run.log" >/dev/null ||
  fail "first-run records a finalization failure"
pass "failed user finalization keeps first-run retryable"

# The same contract has to hold for the real enable-user-units leaf: a unit
# that is installed but fails to enable must keep first-run pending, while the
# historical missing brightness unit alone may still complete. The systemctl
# stub represents a loaded service failing to start, not a missing file.
printf '#!/bin/bash\nexit 0\n' >"$retry_bin/omarchy-provision-user"
cp "$ROOT/install/user/first-run/enable-user-units.sh" "$retry_root/install/user/first-run/enable-user-units.sh"
cat >"$retry_bin/systemctl" <<'SH'
#!/bin/bash
case "$2" in
  enable)
    if [[ $4 == "${FAIL_UNIT:-}" ]]; then
      exit 42
    fi
    ;;
  show) printf '%s\n' "${LOAD_STATE:-loaded}" ;;
esac
SH
chmod +x "$retry_bin/systemctl"

run_unit_first_run() {
  HOME="$retry_tmp/home" PATH="$retry_bin:$PATH" OMARCHY_PATH="$retry_root" \
    OMARCHY_TEST_FIRST_RUN_MARKER="$retry_marker" \
    OMARCHY_TEST_FINALIZE_CALLED="$retry_finalize" \
    bash "$ROOT/bin/omarchy-provision-first-run" >"$retry_tmp/output"
}

first_run_log="$retry_tmp/home/.local/state/omarchy/first-run.log"
for unit in omarchy-sleep-lock.service omarchy-migrate-notify.service; do
  rm -f "$retry_marker"
  # The log is appended across runs, so an earlier iteration's failure line
  # would satisfy this run's assertion.
  : >"$first_run_log"
  FAIL_UNIT="$unit" LOAD_STATE=loaded run_unit_first_run
  [[ ! -e $retry_marker ]] || fail "$unit failure must not mark first-run complete"
  grep -Fq 'Failed: enable user systemd units' "$first_run_log" ||
    fail "enable failure is logged"
  FAIL_UNIT='' run_unit_first_run
  [[ -e $retry_marker ]] || fail "successful retry must mark first-run complete"
done

rm -f "$retry_marker"
FAIL_UNIT=omarchy-brightness-keyboard-auto.service LOAD_STATE=not-found run_unit_first_run
[[ -e $retry_marker ]] || fail "known missing brightness alone may complete first-run"
pass "real unit failures preserve the first-run retry contract"
