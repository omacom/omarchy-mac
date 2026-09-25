#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

fix="$ROOT/bin/omarchy-wifi-resume-fix"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
service="$test_tmp/etc/systemd/system/omarchy-wifi-resume-fix.service"
reload_marker="$test_tmp/reloaded"
mkdir -p "$stub_bin"

cat >"$stub_bin/lspci" <<'SH'
#!/bin/bash

# Chatty like real lspci: keep writing well past the pipe buffer after the
# match, so a grep -q consumer would die of SIGPIPE and pipefail would read
# that as "no such hardware" (#6608).
if [[ -n ${WIFI_ID:-} ]]; then
  echo "01:00.0 Network controller [0280]: Broadcom Inc. Wireless [14e4:$WIFI_ID]"
fi
for _ in {1..4096}; do
  echo '02:00.0 Host bridge [0600]: Filler Device [ffff:0000]'
done
SH

# The recovery is for Apple Silicon, so every case has to say which
# platform it runs on rather than inherit the machine running the suite.
cat >"$stub_bin/omarchy-hw-platform" <<'SH'
#!/bin/bash
[[ ${PLATFORM:-generic} != error ]] || { echo "Error: contradictory platform identity" >&2; exit 1; }
echo "${PLATFORM:-generic}"
SH

cat >"$stub_bin/systemctl" <<'SH'
#!/bin/bash

printf 'systemctl' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
if [[ ${1:-} == "is-enabled" ]]; then
  (( ${SERVICE_ENABLED:-0} == 1 ))
fi
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

printf 'sudo' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
"$@"
SH

cat >"$stub_bin/nmcli" <<'SH'
#!/bin/bash

if [[ $* == "radio wifi" ]]; then
  echo "${RADIO_STATE:-enabled}"
  exit 0
fi
state="${WIFI_STATE:-disconnected}"
if [[ -n ${RELOAD_MARKER:-} && -e ${RELOAD_MARKER:-} ]]; then
  state="connected"
fi
if [[ $* == *"DEVICE,TYPE"* ]]; then
  echo "wlan0:wifi"
else
  echo "wlan0:$state"
fi
SH

cat >"$stub_bin/journalctl" <<'SH'
#!/bin/bash

# Models systemd's journalctl, including the trap that an empty window still
# prints "-- No entries --" to stdout unless -q is passed - a bare emptiness
# check on captured output is dead code against the real tool.
quiet=0
for arg in "$@"; do
  [[ $arg == "-q" ]] && quiet=1
done

if [[ $* == *"--show-cursor"* ]]; then
  if (( ${CURSOR_FAILS:-0} == 1 )); then
    exit 1
  fi
  echo '-- cursor: s=stub;i=deadbeef'
  exit 0
fi

reject="wlan0: Association failed: status ${STATUS_CODE:-16}"
lines=()
if [[ $* == *"--after-cursor"* ]]; then
  # Only what wpa_supplicant logged after resume sits behind the cursor.
  for ((j = 0; j < ${REJECT_LINES:-0}; j++)); do
    lines+=("$reject")
  done
elif [[ $* == *"--since"* ]]; then
  # A --since window trusts the wall clock: empty when the clock stepped
  # backwards across resume (SINCE_EMPTY), the post-resume entries otherwise.
  if (( ${SINCE_EMPTY:-0} == 0 )); then
    for ((j = 0; j < ${REJECT_LINES:-0}; j++)); do
      lines+=("$reject")
    done
  fi
else
  # An unwindowed read sweeps in pre-suspend history too: stale rejects from
  # the last genuine wedge that must never confirm a fresh one.
  for ((j = 0; j < ${REJECT_LINES:-0}; j++)); do
    lines+=("$reject")
  done
  for ((j = 0; j < ${STALE_REJECTS:-0}; j++)); do
    lines+=('wlan0: Association failed: status 16')
  done
fi

if (( ${#lines[@]} == 0 )); then
  (( quiet == 0 )) && echo '-- No entries --'
  exit 0
fi
printf '%s\n' "${lines[@]}"
SH

cat >"$stub_bin/modprobe" <<'SH'
#!/bin/bash

printf 'modprobe' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
if [[ $1 == "-r" ]]; then
  exit "${UNLOAD_FAILS:-0}"
fi
# nmcli reports connected once the marker exists, modelling NetworkManager
# reassociating after the driver comes back.
[[ -n ${RELOAD_MARKER:-} ]] && touch "$RELOAD_MARKER"
exit "${LOAD_FAILS:-0}"
SH

# The command waits out real seconds between polls; the logic under test does
# not depend on the waiting.
cat >"$stub_bin/sleep" <<'SH'
#!/bin/bash

exit 0
SH

chmod +x "$stub_bin"/*

# Redirect the fixed installed gate into this isolated source tree.
sed "s|/usr/lib/omarchy-mac/wifi-supported|$ROOT/lib/wifi-supported|" "$fix" >"$test_tmp/fix"
chmod +x "$test_tmp/fix"
fix="$test_tmp/fix"
export PLATFORM=apple-silicon WIFI_ID=4433

# The recovery command itself: wedge detection and the decision to reload.
run_fix() {
  : >"$calls"
  rm -f "$reload_marker"

  RADIO_STATE="${RADIO_STATE:-enabled}" WIFI_STATE="${WIFI_STATE:-disconnected}" \
    REJECT_LINES="${REJECT_LINES:-0}" SINCE_EMPTY="${SINCE_EMPTY:-0}" \
    CURSOR_FAILS="${CURSOR_FAILS:-0}" STALE_REJECTS="${STALE_REJECTS:-0}" \
    STATUS_CODE="${STATUS_CODE:-16}" \
    UNLOAD_FAILS="${UNLOAD_FAILS:-0}" RELOAD_MARKER="${RELOAD_MARKER-$reload_marker}" \
    PATH="$stub_bin:$PATH" TEST_LOG="$calls" \
    "$fix"
}

# Respecting rfkill and the user: a deliberately disabled radio is not a wedge.
out=$(RADIO_STATE=disabled run_fix) || fail "a disabled radio exits cleanly" "$out"
grep -q 'radio is disabled' <<<"$out" ||
  fail "a disabled radio is reported, not fought" "$out"
[[ ! -s $calls ]] ||
  fail "a disabled radio leaves the driver untouched" "$(cat "$calls")"
pass "a disabled radio exits without touching the driver"

out=$(WIFI_STATE=connected run_fix) || fail "a healthy resume exits cleanly" "$out"
grep -q 'no reload needed' <<<"$out" ||
  fail "a healthy resume needs no reload" "$out"
[[ ! -s $calls ]] ||
  fail "a healthy resume leaves the driver untouched" "$(cat "$calls")"
pass "wifi that comes back on its own is left alone"

# Two ASSOC-REJECT status_code=16 events confirm the wedge and reload without
# sitting out the backstop timer.
out=$(REJECT_LINES=2 run_fix) || fail "a confirmed wedge recovers" "$out"
grep -q 'wedged firmware confirmed after 0s' <<<"$out" ||
  fail "two rejects confirm the wedge immediately" "$out"
grep -Fq $'modprobe\t-r\tbrcmfmac_wcc\tbrcmfmac' "$calls" ||
  fail "a confirmed wedge unloads the driver stack" "$(cat "$calls")"
grep -Fxq $'modprobe\tbrcmfmac' "$calls" ||
  fail "a confirmed wedge reloads the driver" "$(cat "$calls")"
grep -q 'reconnected' <<<"$out" ||
  fail "the reload is followed by a reconnect" "$out"
pass "two association rejects confirm the wedge and reload the driver"

# One reject is not a signature - a healthy association can be refused once -
# so the command waits out the backstop instead of trusting it.
out=$(REJECT_LINES=1 run_fix) || fail "the backstop still recovers" "$out"
! grep -q 'wedged firmware confirmed' <<<"$out" ||
  fail "one reject does not confirm a wedge" "$out"
grep -q 'wifi not back after 12s' <<<"$out" ||
  fail "one reject falls through to the backstop timer" "$out"
grep -Fxq $'modprobe\tbrcmfmac' "$calls" ||
  fail "the backstop still reloads the driver" "$(cat "$calls")"
pass "a single reject waits for the backstop instead of reloading early"

# A status code that merely starts with 16 is a different rejection, not the
# wedge signature.
out=$(REJECT_LINES=2 STATUS_CODE=160 run_fix) ||
  fail "an unrelated status code still recovers via the backstop" "$out"
! grep -q 'wedged firmware confirmed' <<<"$out" ||
  fail "status_code=160 does not count as status_code=16" "$out"
pass "an unrelated status code does not confirm a wedge"

# The cursor pins the journal position, so the clock stepping backwards across
# resume (an RTC quirk on some Apple Silicon kernels) cannot hide the
# signature the way it empties a --since window.
out=$(REJECT_LINES=2 SINCE_EMPTY=1 run_fix) ||
  fail "wedge detection survives a clock step" "$out"
grep -q 'wedged firmware confirmed after 0s' <<<"$out" ||
  fail "the cursor is immune to the clock stepping backwards" "$out"
pass "wedge detection survives the clock stepping backwards across resume"

# Without a cursor the --since window still catches the signature.
out=$(CURSOR_FAILS=1 REJECT_LINES=2 run_fix) ||
  fail "the --since fallback still recovers" "$out"
grep -q 'wedged firmware confirmed after 0s' <<<"$out" ||
  fail "a failed cursor capture falls back to the --since window" "$out"
pass "a failed cursor capture falls back to the --since window"

# With no cursor and an empty window, stale rejects from the last genuine
# wedge sit in the unwindowed journal; counting them would reload the driver
# on a healthy resume. Degrading to the backstop is the correct answer.
out=$(CURSOR_FAILS=1 SINCE_EMPTY=1 STALE_REJECTS=2 run_fix) ||
  fail "an empty window degrades to the backstop" "$out"
! grep -q 'wedged firmware confirmed' <<<"$out" ||
  fail "stale pre-suspend rejects do not confirm a fresh wedge" "$out"
grep -q 'wifi not back after 12s' <<<"$out" ||
  fail "an empty window degrades to the backstop" "$out"
pass "stale journal history never fakes a wedge"

# A driver that will not unload needs a reboot, not a retry loop.
out=$(REJECT_LINES=2 UNLOAD_FAILS=1 run_fix) &&
  fail "a failed unload is reported as a failure" "$out"
grep -q 'failed to unload' <<<"$out" ||
  fail "a failed unload says a reboot is needed" "$out"
pass "a driver that will not unload fails loudly"

# A reload that never reconnects exits nonzero so the journal shows the
# failure instead of a silent success.
out=$(REJECT_LINES=2 RELOAD_MARKER="" run_fix) &&
  fail "a reload that never reconnects is reported as a failure" "$out"
grep -q 'still not connected 30s after reload' <<<"$out" ||
  fail "a reload that never reconnects says so" "$out"
pass "a reload that never reconnects fails loudly"

out=$(LOAD_FAILS=1 run_fix) && fail "failed driver reload must fail" "$out"
grep -q 'failed to reload' <<<"$out" || fail "failed reload is diagnosed" "$out"
for spec in 'generic 4433' 'generic-aarch64 4434' 'qualcomm 4425' 'error 4434' 'apple-silicon 4488' 'apple-silicon 0000'; do
  read -r PLATFORM WIFI_ID <<<"$spec"
  REJECT_LINES=2 run_fix >/dev/null 2>&1
  [[ ! -s $calls ]] || fail "unsupported hardware must not reload" "$spec"
done
pass "failed reload and excluded chipsets are safe"

# BCM4378, BCM4387 and BCM4388 all wedge across s2idle, so each one recovers.
for WIFI_ID in 4425 4433 4434; do
  PLATFORM=apple-silicon
  out=$(REJECT_LINES=2 run_fix) || fail "a wedged $WIFI_ID recovers" "$out"
  grep -Fxq $'modprobe\tbrcmfmac' "$calls" || fail "a wedged $WIFI_ID reloads the driver" "$(cat "$calls")"
done
pass "BCM4378, BCM4387 and BCM4388 recover on Apple Silicon"
