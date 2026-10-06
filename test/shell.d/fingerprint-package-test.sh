#!/bin/bash
#
# The fingerprint setup installs libfprint-git in place of stock libfprint. The
# two conflict, so the swap has to happen inside one --ask 4 transaction, and a
# rerun with everything installed must not touch pacman at all. The real
# omarchy-pkg-missing runs; pacman and the privileged calls are stubbed.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
export CALL_LOG="$scratch/calls"
export PATH="$scratch/bin:$ROOT/bin:$PATH"

cat > "$scratch/bin/omarchy-hw-fingerprint" <<'STUB'
#!/bin/bash
exit "${HARDWARE_STATUS:-0}"
STUB
cat > "$scratch/bin/sudo" <<'STUB'
#!/bin/bash
case "$1" in
  -n) exit "${SUDO_CACHED:-1}" ;;
  -v) echo "sudo authenticated" >> "$CALL_LOG"; exit "${SUDO_V_STATUS:-0}" ;;
  pacman | fprintd-enroll) exec "$@" ;;
  # PAM edits are logged, never made; tee's input is read and dropped.
  sed | tee) echo "privileged $*" >> "$CALL_LOG"; [[ $1 != "tee" ]] || cat > /dev/null ;;
  *) echo "Unexpected privileged call: $*" >> "$CALL_LOG"; exit 99 ;;
esac
STUB
# INSTALLED lists the installed package names, one per line.
cat > "$scratch/bin/pacman" <<'STUB'
#!/bin/bash
case "$1" in
  -Q)
    if [[ $2 == "--" ]]; then
      shift 2
    else
      shift
    fi
    grep -qx -- "$1" <<< "${INSTALLED:-}"
    ;;
  -S)
    printf 'pacman %s\n' "$*" >> "$CALL_LOG"
    exit "${INSTALL_STATUS:-0}"
    ;;
  *) printf 'pacman %s\n' "$*" >> "$CALL_LOG"; exit 99 ;;
esac
STUB
# Both fail unless ENROLL_STATUS or VERIFY_STATUS says otherwise, stopping
# before PAM. ENROLL_OUTPUT is what fprintd-enroll prints first.
cat > "$scratch/bin/fprintd-enroll" <<'STUB'
#!/bin/bash
echo enroll >> "$CALL_LOG"
[[ -z ${ENROLL_OUTPUT:-} ]] || printf '%s\n' "$ENROLL_OUTPUT"
exit "${ENROLL_STATUS:-1}"
STUB
cat > "$scratch/bin/fprintd-verify" <<'STUB'
#!/bin/bash
echo verify >> "$CALL_LOG"
exit "${VERIFY_STATUS:-1}"
STUB
# fprintd on D-Bus: SCAN_TYPE is the default reader's scan type and READER_NAME
# its name; with SCAN_TYPE unset, fprintd doesn't answer. Never the host's own fprintd.
cat > "$scratch/bin/busctl" <<'STUB'
#!/bin/bash
[[ -n ${SCAN_TYPE:-} ]] || exit 1
case "$*" in
  *GetDefaultDevice*) echo 'o "/net/reactivated/Fprint/Device/0"' ;;
  *"/net/reactivated/Fprint/Device/0 net.reactivated.Fprint.Device scan-type"*) echo "s \"$SCAN_TYPE\"" ;;
  *"/net/reactivated/Fprint/Device/0 net.reactivated.Fprint.Device name"*) echo "s \"${READER_NAME:-Some USB reader}\"" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$scratch/bin/"*

run_setup() {
  : > "$CALL_LOG"
  if "$ROOT/bin/omarchy-setup-security-fingerprint" > "$scratch/output" 2>&1; then
    fail "setup stops on the simulated enrollment or installation failure"
  fi
  if grep -q -e 'Unexpected privileged call' -e '^privileged ' "$CALL_LOG"; then
    fail "setup does not change PAM after a failed enrollment, installation or verify"
  fi
}

assert_installs() {
  grep -qx 'pacman -S --needed --noconfirm --ask 4 -- libfprint-git fprintd usbutils' "$CALL_LOG" || fail "$1"
  (( $(grep -c '^pacman ' "$CALL_LOG") == 1 )) || fail "$1: one pacman transaction"
}

run_setup
assert_installs "a fresh machine installs libfprint-git, fprintd and usbutils"
grep -qx enroll "$CALL_LOG" || fail "installation is followed by enrollment"
pass "a fresh machine installs libfprint-git and reaches enrollment"

INSTALLED=$'libfprint\nfprintd\nusbutils' run_setup
assert_installs "installed stock libfprint is replaced in the same transaction"
pass "installed stock libfprint is replaced without a removal step"

INSTALLED=$'libfprint-git\nfprintd\nusbutils' run_setup
if grep -q '^pacman' "$CALL_LOG"; then
  fail "a rerun with everything installed does not touch pacman"
fi
grep -qx enroll "$CALL_LOG" || fail "a rerun with everything installed reaches enrollment"
pass "a rerun with everything installed goes straight to enrollment"

INSTALL_STATUS=1 run_setup
if grep -qx enroll "$CALL_LOG"; then
  fail "a failed package transaction prevents enrollment"
fi
pass "a failed installation stops before enrollment"

HARDWARE_STATUS=1 run_setup
[[ ! -s $CALL_LOG ]] || fail "missing hardware stops before package operations"
pass "missing hardware performs no package operations"

# A press sensor, such as a Mac's Touch ID, takes a touch per sample, so setup
# says to lift and touch again; a swipe sensor, or none fprintd can name, keeps
# the moving-finger instruction.
press_text="Touch the sensor, lift your finger and touch it again, and keep going until it says Enrolled. A step can take a few touches."
swipe_text="Keep moving the finger around on sensor until it says Enrolled."
INSTALLED=$'libfprint-git\nfprintd\nusbutils' SCAN_TYPE=press run_setup
grep -qF "$press_text" "$scratch/output" && ! grep -qF "$swipe_text" "$scratch/output" ||
  fail "a press sensor is told to lift and touch again" "$(cat "$scratch/output")"
for scan_type in swipe ""; do
  INSTALLED=$'libfprint-git\nfprintd\nusbutils' SCAN_TYPE=$scan_type run_setup
  grep -qF "$swipe_text" "$scratch/output" && ! grep -qF "$press_text" "$scratch/output" ||
    fail "a ${scan_type:-unnamed} sensor keeps the moving-finger instruction" "$(cat "$scratch/output")"
done
pass "a press sensor is told to touch again, and any other keeps the moving-finger instruction"

# fprintd-enroll's raw results become instructions. Touch ID's duplicate check
# stage prints nothing; later stages count as steps, never touches, since one
# stage can take several.
enroll_lines=$'Using device /net/reactivated/Fprint/Device/0\nEnrolling right-index-finger finger.'
for result in stage-passed stage-passed retry-scan stage-passed unknown-error; do
  enroll_lines+=$'\nEnroll result: enroll-'$result
done
INSTALLED=$'libfprint-git\nfprintd\nusbutils' SCAN_TYPE=press READER_NAME='Apple secure enclave fingerprint sensor' \
  ENROLL_OUTPUT=$enroll_lines run_setup
expected=$'  \u2713 Step 1 done. Keep lifting your finger and touching the sensor.
  That one didn\'t read. Keep lifting your finger and touching the sensor.
  \u2713 Step 2 done. Keep lifting your finger and touching the sensor.
  \u2717 Enrollment stopped. If you stopped before it said Enrolled, run this again and keep going.'
[[ $(grep -E '^  ' "$scratch/output") == "$expected" ]] ||
  fail "enrollment results read as instructions, counting steps after the duplicate check" "$(cat "$scratch/output")"
! grep -q 'Enroll result:' "$scratch/output" || fail "no raw fprintd result reaches the owner" "$(cat "$scratch/output")"
grep -q 'Enrollment failed' "$scratch/output" || fail "a failed enrollment still fails setup" "$(cat "$scratch/output")"
pass "enrollment results read as instructions, and a failed enrollment still fails setup"

# PAM changes only after an enrolled print verifies; a failed verify fails setup.
: > "$CALL_LOG"
if INSTALLED=$'libfprint-git\nfprintd\nusbutils' SCAN_TYPE=press ENROLL_STATUS=0 VERIFY_STATUS=1 \
  "$ROOT/bin/omarchy-setup-security-fingerprint" > "$scratch/output" 2>&1; then
  fail "a failed verify fails setup" "$(cat "$scratch/output")"
fi
grep -qx verify "$CALL_LOG" && ! grep -q '^privileged ' "$CALL_LOG" ||
  fail "a failed verify leaves PAM alone" "$(cat "$CALL_LOG")"
: > "$CALL_LOG"
INSTALLED=$'libfprint-git\nfprintd\nusbutils' SCAN_TYPE=press ENROLL_STATUS=0 VERIFY_STATUS=0 \
  "$ROOT/bin/omarchy-setup-security-fingerprint" > "$scratch/output" 2>&1 ||
  fail "a verified print completes setup" "$(cat "$scratch/output")"
# Only the lock-screen file is written whatever the host's /etc/pam.d holds.
verified=$(grep -nx verify "$CALL_LOG" | cut -d: -f1)
lock_pam=$(grep -n '^privileged tee /etc/pam.d/omarchy-lock-fingerprint$' "$CALL_LOG" | cut -d: -f1)
[[ -n $verified && -n $lock_pam ]] && (( verified < lock_pam )) ||
  fail "PAM is written after verify" "$(cat "$CALL_LOG")"
pass "PAM is written only after a print verifies, and a failed verify fails setup"

# The verify step's results, in fprintd-verify's own format (each with " (done)"
# or " (not done)"), through the functions setup uses.
source <(sed -n '/^fprintd_chatter()/,/^}/p;/^enroll_progress()/,/^}/p;/^verify_progress()/,/^}/p' \
  "$ROOT/bin/omarchy-setup-security-fingerprint")
[[ $(printf '%s\n' 'Using device /net/reactivated/Fprint/Device/0' 'Listing enrolled fingers:' ' - #0: right-index-finger' \
  'Verify started!' 'Verifying: right-index-finger' 'Verify result: verify-retry-scan (not done)' \
  'Verify result: verify-finger-not-centered (not done)' 'Verify result: verify-match (done)' |
  verify_progress "Touch again.") == $'  That one didn\'t read. Touch again.\n  Not centered: use the middle of the sensor. Touch again.\n  \u2713 Matched.' ]] ||
  fail "verify results, retries included, read as instructions"
[[ $(printf '%s\n' 'Verify result: verify-no-match (done)' | verify_progress "Touch again.") == $'  \u2717 No match.' ]] ||
  fail "a failed verify says so"
pass "verify results read as instructions"

# Only Touch ID's first stage is its duplicate check. On any other reader, one
# that doesn't identify or one whose duplicate check took a touch, the first
# stage to pass is step 1.
INSTALLED=$'libfprint-git\nfprintd\nusbutils' SCAN_TYPE=press ENROLL_OUTPUT=$enroll_lines run_setup
[[ $(grep -c 'Step [0-9] done' "$scratch/output") == 3 ]] ||
  fail "another reader's first stage is step 1" "$(cat "$scratch/output")"
INSTALLED=$'libfprint-git\nfprintd\nusbutils' ENROLL_OUTPUT=$enroll_lines run_setup
[[ $(grep -c 'Step [0-9] done' "$scratch/output") == 3 ]] ||
  fail "a reader fprintd can't name has its first stage counted" "$(cat "$scratch/output")"
[[ $(printf '%s\n' 'Enroll result: enroll-stage-passed' 'Enroll result: enroll-stage-passed' | enroll_progress "Again." 1) == \
  $'  \u2713 Step 1 done. Again.' ]] || fail "with a duplicate check, the first stage is not a step"
pass "only a reader with a duplicate check leaves its first stage out of the steps"

# sudo's own prompt comes first and is named as such; with sudo already
# authenticated there is no prompt to explain.
INSTALLED=$'libfprint-git\nfprintd\nusbutils' SCAN_TYPE=press run_setup
grep -qF "First, confirm it's you." "$scratch/output" && grep -qx 'sudo authenticated' "$CALL_LOG" ||
  fail "setup names sudo's prompt and authenticates before enrolling" "$(cat "$scratch/output")"
(( $(grep -n "First, confirm it's you." "$scratch/output" | cut -d: -f1) < $(grep -n "Let's set up" "$scratch/output" | cut -d: -f1) )) ||
  fail "sudo's prompt comes before the enrollment instructions" "$(cat "$scratch/output")"
INSTALLED=$'libfprint-git\nfprintd\nusbutils' SCAN_TYPE=press SUDO_CACHED=0 run_setup
! grep -qF "First, confirm it's you." "$scratch/output" && ! grep -qx 'sudo authenticated' "$CALL_LOG" ||
  fail "an authenticated sudo is not asked again" "$(cat "$scratch/output")"
pass "sudo is authenticated, and named, before the enrollment instructions"

# What fprintd prints when it can't go on (a claimed device, no fingers) is
# shown; its routine lines are not.
[[ $(printf '%s\n' 'Using device /net/reactivated/Fprint/Device/0' \
  'failed to claim device: GDBus.Error:net.reactivated.Fprint.Error.AlreadyInUse: Device was already claimed' |
  enroll_progress "Touch again.") == '  failed to claim device: GDBus.Error:net.reactivated.Fprint.Error.AlreadyInUse: Device was already claimed' ]] ||
  fail "why enrollment could not start is shown"
[[ $(printf '%s\n' 'Using device /net/reactivated/Fprint/Device/0' 'No fingers enrolled for this device.' |
  verify_progress "Touch again.") == '  No fingers enrolled for this device.' ]] || fail "why verify could not start is shown"
pass "fprintd's reasons for stopping reach the owner, its routine lines do not"

# A sudo that won't authenticate stops setup with a reason, before enrolling.
INSTALLED=$'libfprint-git\nfprintd\nusbutils' SCAN_TYPE=press SUDO_V_STATUS=1 run_setup
grep -qF "Setup needs administrator rights to enroll a fingerprint." "$scratch/output" && ! grep -qx enroll "$CALL_LOG" ||
  fail "a failed sudo stops setup with a reason" "$(cat "$scratch/output")"
pass "a failed sudo stops setup with a reason, before enrolling"

# Every retry fprintd 1.94.5 can send keeps enrollment going; only a failure
# says it stopped, and a result fprintd adds later is shown, not called a stop.
[[ $(printf '%s\n' 'Enrolling right-index-finger finger.' 'Enroll result: enroll-stage-passed' 'Enroll result: enroll-too-fast' \
  'Enroll result: enroll-swipe-too-short' 'Enroll result: enroll-stage-passed' 'Enroll result: enroll-some-new-result' \
  'Enroll result: enroll-completed' | enroll_progress "Swipe it again." 1) == $'  Too fast. Swipe it again.\n  Too short. Swipe it again.\n  \u2713 Step 1 done. Swipe it again.\n  enroll-some-new-result\n  \u2713 Enrolled.' ]] ||
  fail "enrollment retries keep going, and an unknown result is shown"
[[ $(printf '%s\n' 'Verify result: verify-too-fast (not done)' 'Verify result: verify-some-new-retry (not done)' \
  'Verify result: verify-disconnected (done)' | verify_progress "Swipe it again.") == $'  Too fast. Swipe it again.\n  That one didn\'t read. Swipe it again.\n  \u2717 The check stopped.' ]] ||
  fail "any verify result that isn't done is a retry"
pass "every retry keeps the step going, and only a finished failure says it stopped"

# Each of fprintd 1.94.5's enroll and verify results, one by one.
check_enroll() {
  [[ $(printf 'Enroll result: %s\n' "$1" | enroll_progress "Again.") == "$2" ]] ||
    fail "enroll result $1 reads as: $2" "$(printf 'Enroll result: %s\n' "$1" | enroll_progress "Again.")"
}
check_enroll enroll-completed $'  ✓ Enrolled.'
check_enroll enroll-retry-scan "  That one didn't read. Again."
check_enroll enroll-swipe-too-short '  Too short. Again.'
check_enroll enroll-finger-not-centered '  Not centered: use the middle of the sensor. Again.'
check_enroll enroll-remove-and-retry '  Lift your finger off the sensor, then: Again.'
check_enroll enroll-too-fast '  Too fast. Again.'
check_enroll enroll-duplicate $'  ✗ That finger is already enrolled.'
check_enroll enroll-data-full $'  ✗ The reader has no room for another fingerprint.'
check_enroll enroll-disconnected $'  ✗ The reader was disconnected.'
for result in enroll-failed enroll-unknown-error; do
  check_enroll "$result" $'  ✗ Enrollment stopped. If you stopped before it said Enrolled, run this again and keep going.'
done
check_verify() {
  [[ $(printf 'Verify result: %s\n' "$1" | verify_progress "Again.") == "$2" ]] ||
    fail "verify result $1 reads as: $2" "$(printf 'Verify result: %s\n' "$1" | verify_progress "Again.")"
}
check_verify 'verify-match (done)' $'  ✓ Matched.'
check_verify 'verify-no-match (done)' $'  ✗ No match.'
check_verify 'verify-retry-scan (not done)' "  That one didn't read. Again."
check_verify 'verify-swipe-too-short (not done)' '  Too short. Again.'
check_verify 'verify-finger-not-centered (not done)' '  Not centered: use the middle of the sensor. Again.'
check_verify 'verify-remove-and-retry (not done)' '  Lift your finger off the sensor, then: Again.'
check_verify 'verify-too-fast (not done)' '  Too fast. Again.'
for result in verify-disconnected verify-unknown-error; do
  check_verify "$result (done)" $'  ✗ The check stopped.'
done
pass "each enroll and verify result fprintd 1.94.5 sends reads as intended"
