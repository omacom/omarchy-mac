#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
mkdir -p "$test_tmp/home" "$test_tmp/packaged"
ln -s "$stub_bin" "$test_tmp/packaged/bin"
# The installed-path reset must resolve to fixture helpers too. Keep the
# updater logic unchanged and substitute only its package root in this copy.
sed "s|/usr/share/omarchy|$test_tmp/packaged|g" "$ROOT/bin/omarchy-update" >"$test_tmp/channel-update"

# Every step omarchy-update runs, recorded in order with the unattended flag it
# was handed. One of them can be told to fail.
steps=(
  omarchy-update-lock
  omarchy-update-requires-free-space
  omarchy-update-confirm
  omarchy-update-pkg-prune
  omarchy-snapshot
  omarchy-update-stay-awake
  omarchy-update-dev
  omarchy-update-keyring
  omarchy-update-system-pkgs
  omarchy-migrate
  omarchy-hook
  omarchy-update-aur-pkgs
  omarchy-update-mise
  omarchy-update-orphan-pkgs
  omarchy-update-analyze-logs
  omarchy-update-status
  omarchy-update-restart
  omarchy-dev-unlink
  omarchy-state
)

for step in "${steps[@]}"; do
  cat >"$stub_bin/$step" <<'STUB'
#!/bin/bash
printf '%s unattended=%s\n' "${0##*/}" "${OMARCHY_UPDATE_UNATTENDED:-}" >>"$STEP_LOG"
[[ ${FAILING_STEP:-} != "${0##*/}" ]] || exit 1
STUB
  chmod +x "$stub_bin/$step"
done

# OMARCHY_UPDATE_LOGGED stands in for the script(1) wrapper the update re-execs
# itself under; the stubbed lock reports itself already held.
run_update() {
  : >"$test_tmp/steps"
  STEP_LOG="$test_tmp/steps" \
    FAILING_STEP="${FAILING_STEP:-}" \
    OMARCHY_UPDATE_LOGGED=1 \
    HOME="$test_tmp/home" \
    PATH="$stub_bin:$PATH" \
    bash "${UPDATE_TEST_SCRIPT:-$ROOT/bin/omarchy-update}" "$@" >"$test_tmp/out" 2>"$test_tmp/err"
}

steps_run() {
  cut -d' ' -f1 "$test_tmp/steps"
}

# Every step of a whole update, in order. $1 asks for the one a person confirms.
# Stay Awake bookends the work, so it is here twice.
expected_steps() {
  printf '%s\n' \
    omarchy-update-lock \
    omarchy-update-requires-free-space \
    ${1:+omarchy-update-confirm} \
    omarchy-update-pkg-prune \
    omarchy-snapshot \
    omarchy-update-stay-awake \
    omarchy-update-dev \
    omarchy-update-keyring \
    omarchy-update-system-pkgs \
    omarchy-migrate \
    omarchy-hook \
    omarchy-update-aur-pkgs \
    omarchy-update-mise \
    omarchy-update-orphan-pkgs \
    omarchy-update-analyze-logs \
    omarchy-update-status \
    omarchy-update-stay-awake \
    omarchy-update-restart
}

run_update -y || fail "an update where everything works reports a failure"
diff <(expected_steps) <(steps_run) >"$test_tmp/order" ||
  fail "an update where everything works does not run every step in order" "$(cat "$test_tmp/order")"
pass "an update where every step works runs all of them, in order"

grep -q '^omarchy-update-system-pkgs unattended=1$' "$test_tmp/steps" ||
  fail "-y does not mark the update unattended"
run_update </dev/null || fail "a confirmed update reports a failure"
diff <(expected_steps confirmed) <(steps_run) >"$test_tmp/order" ||
  fail "a confirmed update runs a different set of steps" "$(cat "$test_tmp/order")"
grep -q '^omarchy-update-system-pkgs unattended=$' "$test_tmp/steps" ||
  fail "an update a person confirmed is treated as unattended"
pass "-y is what marks an update unattended, not the update itself"

# Migrations ship with the packages the upgrade installs and are written against
# them. Running them against what is still on disk is the failure this ordering
# exists to prevent, so the update stops where the packages did.
if FAILING_STEP=omarchy-update-system-pkgs run_update -y; then
  fail "an update whose packages did not upgrade passes for a whole one"
fi
for step in omarchy-migrate omarchy-hook omarchy-update-aur-pkgs omarchy-update-restart; do
  if grep -q "^$step " "$test_tmp/steps"; then
    fail "a blocked package upgrade still runs $step"
  fi
done
pass "a blocked package upgrade stops the update before it migrates"

# A channel update uses one system transaction under the same snapshot/lock
# boundary; it must not first install keyrings or update an old dev checkout.
UPDATE_TEST_SCRIPT="$test_tmp/channel-update" OMARCHY_PATH="$ROOT" OMARCHY_UPDATE_CHANNEL=rc run_update -y || fail "channel update succeeds"
[[ $(grep -c '^omarchy-update-system-pkgs ' "$test_tmp/steps") == 1 ]] || fail "channel update has one system package transaction"
! grep -Eq '^omarchy-update-(dev|keyring) ' "$test_tmp/steps" || fail "channel update does not mutate sources or install keyrings before staging"
[[ $(steps_run | awk '/omarchy-update-system-pkgs/,/omarchy-migrate/') == $'omarchy-update-system-pkgs\nomarchy-dev-unlink\nomarchy-state\nomarchy-migrate' ]] || fail "channel migration follows transaction and package-backed path restoration"
pass "channel update retains lock and snapshot orchestration around a single system transaction"

if UPDATE_TEST_SCRIPT="$test_tmp/channel-update" OMARCHY_PATH="$ROOT" OMARCHY_UPDATE_CHANNEL=rc FAILING_STEP=omarchy-update-system-pkgs run_update -y; then
  fail "failed channel transaction cannot complete its update"
fi
! grep -Eq '^(omarchy-dev-unlink|omarchy-migrate) ' "$test_tmp/steps" || fail "failed channel transaction cannot change runtime path or run migrations"
if UPDATE_TEST_SCRIPT="$test_tmp/channel-update" OMARCHY_PATH="$ROOT" OMARCHY_UPDATE_CHANNEL=rc FAILING_STEP=omarchy-migrate run_update -y; then
  fail "failed channel migration cannot pass for a complete update"
fi
! grep -Eq '^(omarchy-hook|omarchy-update-restart) ' "$test_tmp/steps" || fail "failed channel migration stops downstream work"
pass "channel transaction and migration failures propagate without downstream success"
