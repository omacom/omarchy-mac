#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/fix-wifi-resume.sh"
all="$ROOT/install/hardware/all.sh"
migration="$ROOT/migrations/1787753224.sh"
fix="$ROOT/bin/omarchy-wifi-resume-fix"

[[ -f $leaf ]] || fail "the Wi-Fi resume recovery leaf ships"
grep -Fq 'apple/fix-wifi-resume.sh' "$all" ||
  fail "Wi-Fi resume recovery runs during hardware setup"
[[ -f $migration ]] || fail "existing installs get the Wi-Fi resume recovery"
pass "fresh and existing installs are wired to Wi-Fi resume recovery"

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
# architecture it runs on rather than inherit the machine running the suite.
cat >"$stub_bin/uname" <<'SH'
#!/bin/bash

if [[ ${1:-} == "-m" ]]; then
  echo "${ARCH:-x86_64}"
else
  exec /usr/bin/uname "$@"
fi
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

reject="wlan0: CTRL-EVENT-ASSOC-REJECT bssid=aa:bb:cc:dd:ee:ff status_code=${STATUS_CODE:-16}"
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
    lines+=('wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:11:22:33:44:55 status_code=16')
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
exit 0
SH

# The command waits out real seconds between polls; the logic under test does
# not depend on the waiting.
cat >"$stub_bin/sleep" <<'SH'
#!/bin/bash

exit 0
SH

chmod +x "$stub_bin"/*

# The dependency guard goes through the repo's own helper, not the suite
# machine's installed copy.
ln -s "$ROOT/bin/omarchy-cmd-missing" "$stub_bin/omarchy-cmd-missing"

# The leaf writes the unit under /etc/systemd/system; redirect that into the
# sandbox. run_logged sources leaves under bash -eE, and the migration runs
# the same file under pipefail, so exercise the stricter of the two.
sandboxed_leaf="$test_tmp/fix-wifi-resume.sh"
sed "s|/etc/systemd/system|$test_tmp/etc/systemd/system|g" "$leaf" >"$sandboxed_leaf"

run_leaf() {
  local arch="$1" wifi_id="${2:-}"
  rm -rf "$test_tmp/etc"
  mkdir -p "$test_tmp/etc/systemd/system"
  : >"$calls"

  ARCH="$arch" WIFI_ID="$wifi_id" PATH="$stub_bin:$PATH" TEST_LOG="$calls" \
    bash -eE -o pipefail -c 'source "$1"' bash "$sandboxed_leaf" </dev/null
}

# Both wedging parts: BCM4378 in M1-era Macs, BCM4387 in M2-era ones.
for wifi_id in 4425 4433; do
  run_leaf aarch64 "$wifi_id" >/dev/null
  [[ -f $service ]] ||
    fail "an Apple Silicon Mac gets the recovery service" "14e4:$wifi_id"
  grep -Fq $'systemctl\tenable\tomarchy-wifi-resume-fix.service' "$calls" ||
    fail "the recovery service is enabled" "$(cat "$calls")"
done
pass "an Apple Silicon Mac with wedging Broadcom Wi-Fi gets the recovery service"

# The service must never delay resume itself: ordered after the sleep targets,
# not hooked into the suspend path.
grep -q 'After=suspend.target' "$service" ||
  fail "the service is ordered after resume instead of blocking it" "$(cat "$service")"
# Without WantedBy= the stub systemctl would still say enabled while the real
# one refuses, shipping a service that never runs.
grep -q 'WantedBy=suspend.target' "$service" ||
  fail "the service is wanted by the sleep targets" "$(cat "$service")"
pass "the service is ordered after resume instead of blocking it"

# The unit's ExecStart and the shipped command must not drift apart on a
# rename.
exec_start=$(sed -n 's|^ExecStart=/usr/bin/||p' "$service")
[[ -x $ROOT/bin/$exec_start ]] ||
  fail "the unit starts a command this repo ships" "ExecStart resolves to: $exec_start"
pass "the unit starts a command this repo ships"

# BCM4388 (14e4:4434) does not wedge: an M2 Max carrying it rode out a
# six-minute s2idle with no ASSOC-REJECT events (PR #255 review), so the
# exclusion is deliberate and reloading its driver would be pure disruption.
run_leaf aarch64 4434 >/dev/null
[[ ! -f $service ]] || fail "BCM4388 is left alone"
[[ ! -s $calls ]] || fail "nothing is enabled on BCM4388" "$(cat "$calls")"
pass "BCM4388, whose firmware does not wedge, is left alone"

# The same PCI IDs appear in T2 Intel Macs, where suspend takes another path.
for wifi_id in 4425 4433; do
  run_leaf x86_64 "$wifi_id" >/dev/null
  [[ ! -f $service ]] || fail "a T2 Intel Mac is left alone" "14e4:$wifi_id"
done
pass "a T2 Intel Mac with the same PCI IDs is left alone"

run_leaf aarch64 "" >/dev/null
[[ ! -f $service ]] || fail "a machine without Broadcom Wi-Fi is left alone"
pass "a machine without Broadcom Wi-Fi is left alone"

# Installs that predate the recovery never ran the leaf, so the migration has
# to reach them. It runs as the user under pipefail, the context #6608 was
# about, and the chatty lspci stub is what keeps that pinned.
fake_omarchy="$test_tmp/omarchy/install/hardware/apple"
mkdir -p "$fake_omarchy"
cp "$sandboxed_leaf" "$fake_omarchy/fix-wifi-resume.sh"

run_migration() {
  local arch="$1" wifi_id="${2:-}" enabled="${3:-0}"
  rm -rf "$test_tmp/etc"
  mkdir -p "$test_tmp/etc/systemd/system"
  : >"$calls"

  ARCH="$arch" WIFI_ID="$wifi_id" SERVICE_ENABLED="$enabled" \
    PATH="$stub_bin:$PATH" TEST_LOG="$calls" OMARCHY_PATH="$test_tmp/omarchy" \
    bash -euo pipefail "$migration" >/dev/null
}

run_migration aarch64 4433
[[ -f $service ]] ||
  fail "the migration installs the recovery on an existing install" "$(cat "$calls")"
grep -Fq $'systemctl\tenable\tomarchy-wifi-resume-fix.service' "$calls" ||
  fail "the migration enables the recovery service" "$(cat "$calls")"
pass "the migration installs the recovery on an existing install"

# Another user on the machine may already have applied the repair.
run_migration aarch64 4433 1
[[ ! -f $service ]] || fail "an already repaired machine is left untouched"
! grep -q 'sudo' "$calls" ||
  fail "the migration escalates nothing when already repaired" "$(cat "$calls")"
pass "the migration is idempotent"

run_migration x86_64 4433
[[ ! -f $service ]] || fail "the migration skips a T2 Intel Mac"
run_migration aarch64 4434
[[ ! -f $service ]] || fail "the migration skips BCM4388"
pass "the migration skips machines the leaf would skip"

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

# The dependency guard: a missing tool is a loud failure, not a silent hang.
dep_bin="$test_tmp/dep-bin"
mkdir -p "$dep_bin"
ln -s "$(command -v date)" "$dep_bin/date"
ln -s "$(command -v sed)" "$dep_bin/sed"
ln -s "$ROOT/bin/omarchy-cmd-missing" "$dep_bin/omarchy-cmd-missing"
cp "$stub_bin/nmcli" "$stub_bin/journalctl" "$dep_bin/"
out=$(PATH="$dep_bin" TEST_LOG="$calls" "$fix") &&
  fail "a missing dependency is reported as a failure" "$out"
grep -q 'missing modprobe' <<<"$out" ||
  fail "the missing dependency is named" "$out"
pass "a missing dependency fails loudly instead of hanging"
