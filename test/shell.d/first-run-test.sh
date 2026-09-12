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

# Exercise the full completion gate with the real notification parser and the
# three leaves involved in the recurring update prompt. Stub only unrelated
# setup and the external service/network/notification transports.
require_command jq
lifecycle="$retry_tmp/lifecycle"
mkdir -p "$lifecycle/bin" "$lifecycle/omarchy/install/user/first-run"
for leaf in timezone wifi enable-user-units; do
  cp "$ROOT/install/user/first-run/$leaf.sh" "$lifecycle/omarchy/install/user/first-run/"
done
for leaf in welcome gnome-theme gtk-primary-paste audio-tuning; do
  printf 'true\n' >"$lifecycle/omarchy/install/user/first-run/$leaf.sh"
done
for command in omarchy-provision-user omarchy-hook-install omarchy-notification-wait nm-online; do
  printf '#!/bin/bash\nexit 0\n' >"$lifecycle/bin/$command"
done
printf '#!/bin/bash\nprintf "UTC\\n"\n' >"$lifecycle/bin/timedatectl"
cat >"$lifecycle/bin/systemctl" <<'SH'
#!/bin/bash
[[ $* != '--user daemon-reload' ]] || exit 0
[[ ${KEYBOARD_UNIT_PRESENT:-yes} == yes ]]
SH
cat >"$lifecycle/bin/busctl" <<'SH'
#!/bin/bash
for argument in "$@"; do
  [[ $argument != 'Update System' ]] || printf 'update\n' >>"$NOTIFICATIONS"
done
exit 0
SH
chmod +x "$lifecycle/bin/"*

login() {
  HOME="$lifecycle/home" XDG_CONFIG_HOME="$lifecycle/home/.config" \
    PATH="$lifecycle/bin:$ROOT/bin:$PATH" OMARCHY_PATH="$lifecycle/omarchy" \
    NOTIFICATIONS="$lifecycle/notifications" KEYBOARD_UNIT_PRESENT="$1" \
    bash "$ROOT/bin/omarchy-provision-first-run" 2>&1 | cat >"$lifecycle/output"
  # wifi.sh detaches its network probe. A pipe stays open until that child
  # exits, giving each simulated login a deterministic notification boundary.
}

marker="$lifecycle/home/.local/state/omarchy/done/first-run-user"
login yes
login yes
[[ -f $marker ]] || fail "successful real first-run records completion"
[[ $(wc -l <"$lifecycle/notifications") == 1 ]] || fail "two successful logins show the update prompt once"
pass "real timezone action and shipped user unit allow first-run to finish once"

rm -rf "$lifecycle/home" "$lifecycle/notifications"
login no
[[ ! -e $marker ]] || fail "missing user unit keeps first-run retryable"
login yes
[[ -f $marker ]] || fail "restored user unit allows the next login to finish"
login yes
[[ $(wc -l <"$lifecycle/notifications") == 2 ]] || fail "repair stops update prompts after the successful retry"
pass "missing package unit retries setup until repaired, then stops repeating prompts"
