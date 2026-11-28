#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/fix-bluetooth-resume.sh"
all="$ROOT/install/hardware/all.sh"
fix="$ROOT/bin/omarchy-bluetooth-resume-fix"

[[ -f $leaf ]] || fail "the Bluetooth resume recovery leaf ships"
grep -Fq 'apple/fix-bluetooth-resume.sh' "$all" ||
  fail "Bluetooth resume recovery runs during hardware setup"
migration=$(grep -rlF 'fix-bluetooth-resume.sh' "$ROOT/migrations" 2>/dev/null | head -1)
[[ -n $migration ]] || fail "existing installs get the Bluetooth resume recovery"
pass "fresh and existing installs are wired to Bluetooth resume recovery"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
service="$test_tmp/etc/systemd/system/omarchy-bluetooth-resume-fix.service"
mkdir -p "$stub_bin"

cat >"$stub_bin/lspci" <<'SH'
#!/bin/bash

# Chatty like real lspci: keep writing well past the pipe buffer after the
# match, so a grep -q consumer would die of SIGPIPE and pipefail would read
# that as "no such hardware" (#6608).
if [[ -n ${BT_ID:-} ]]; then
  echo "01:00.1 Network controller [0280]: Broadcom Inc. Bluetooth [14e4:$BT_ID]"
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

# Models the kernel journal in the order a real resume writes it: the suspend
# entry, then the tx timeouts during device resume, then "PM: suspend exit"
# last of all. A read anchored on the exit marker therefore finds nothing.
cat >"$stub_bin/journalctl" <<'SH'
#!/bin/bash

if [[ -n ${TEST_LOG:-} ]]; then
  printf 'journalctl' >>"$TEST_LOG"
  printf '\t%s' "$@" >>"$TEST_LOG"
  printf '\n' >>"$TEST_LOG"
fi

quiet=0
for arg in "$@"; do
  [[ $arg == "-q" || $arg == "-kq" ]] && quiet=1
done

if [[ $* == *"--show-cursor"* ]]; then
  if (( ${NO_SUSPEND_MARKER:-0} == 1 )); then
    (( quiet == 0 )) && echo '-- No entries --'
    exit 0
  fi
  if [[ $* == *"suspend exit"* ]]; then
    echo '-- cursor: s=stub;i=exit'
  else
    echo '-- cursor: s=stub;i=entry'
  fi
  exit 0
fi

lines=()
timeout='Bluetooth: hci0: command 0x0c01 tx timeout'
if [[ $* == *"--after-cursor"*"i=exit"* ]]; then
  # The timeouts were logged ahead of the exit marker, so none sit behind it.
  :
elif [[ $* == *"--after-cursor"* ]]; then
  # Everything after the suspend entry: the whole suspend and resume path.
  for ((j = 0; j < ${WEDGE_LINES:-0}; j++)); do
    lines+=("$timeout")
  done
elif [[ $* == *"--since"* ]]; then
  # A --since window trusts the wall clock: empty when the clock stepped
  # backwards across resume, the post-resume entries otherwise.
  if (( ${SINCE_EMPTY:-0} == 0 )); then
    for ((j = 0; j < ${WEDGE_LINES:-0}; j++)); do
      lines+=("$timeout")
    done
  fi
fi

if (( ${#lines[@]} == 0 )); then
  (( quiet == 0 )) && echo '-- No entries --'
  exit 0
fi
printf '%s\n' "${lines[@]}"
SH

cat >"$stub_bin/rfkill" <<'SH'
#!/bin/bash

# An absent radio prints nothing at all, which is not the same as a blocked
# one. The default has to survive an empty RADIO_SOFT, so no colon here: that
# is exactly the case being modelled.
[[ -z ${RADIO_SOFT-unblocked} ]] && exit 0
echo "${RADIO_SOFT-unblocked}"
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
sandboxed_leaf="$test_tmp/fix-bluetooth-resume.sh"
sed "s|/etc/systemd/system|$test_tmp/etc/systemd/system|g" "$leaf" >"$sandboxed_leaf"

run_leaf() {
  local arch="$1" bt_id="${2:-}"
  rm -rf "$test_tmp/etc"
  mkdir -p "$test_tmp/etc/systemd/system"
  : >"$calls"

  ARCH="$arch" BT_ID="$bt_id" PATH="$stub_bin:$PATH" TEST_LOG="$calls" \
    bash -eE -o pipefail -c 'source "$1"' bash "$sandboxed_leaf" </dev/null
}

# Both wedging parts: BCM4378 in M1-era Macs, BCM4387 in M2-era ones.
for bt_id in 5f69 5f71; do
  run_leaf aarch64 "$bt_id" >/dev/null
  [[ -f $service ]] ||
    fail "an Apple Silicon Mac gets the recovery service" "14e4:$bt_id"
  grep -Fq $'systemctl\tenable\tomarchy-bluetooth-resume-fix.service' "$calls" ||
    fail "the recovery service is enabled" "$(cat "$calls")"
done
pass "an Apple Silicon Mac with wedging Broadcom Bluetooth gets the recovery service"

# BCM4388 has only ever been reported wedging through the rfkill path, so it
# must not pick up a resume service it has no need for.
run_leaf aarch64 5f72 >/dev/null
[[ -f $service ]] && fail "BCM4388 is left out until a resume wedge is reported there"
run_leaf x86_64 5f69 >/dev/null
[[ -f $service ]] && fail "a T2 Intel Mac does not get the Apple Silicon recovery"
pass "the service is confined to the parts that wedge across resume"

run_leaf aarch64 5f69 >/dev/null
# The service must never delay resume itself: ordered after the sleep targets,
# not hooked into the suspend path.
grep -q 'After=suspend.target' "$service" ||
  fail "the recovery is ordered after resume, not into the suspend path"
grep -q 'WantedBy=suspend.target' "$service" ||
  fail "the recovery is pulled in by the sleep targets"
grep -q 'ExecStart=/usr/bin/omarchy-bluetooth-resume-fix' "$service" ||
  fail "the service runs the recovery command"
pass "the recovery service runs on resume without delaying it"

driver="$test_tmp/driver"
class="$test_tmp/class"
device="0000:01:00.1"

run_fix() {
  rm -rf "$driver" "$class"
  mkdir -p "$driver" "$class"
  : >"$driver/unbind"
  : >"$driver/bind"
  # A controller the class dir already knows about, so the wait after a
  # rebind finishes instead of sitting out its full timeout.
  touch "$class/hci0"
  [[ ${DEVICE_BOUND:-1} == 1 ]] && touch "$driver/$device"
  : >"$calls"

  PATH="$stub_bin:$PATH" TEST_LOG="$calls" \
    OMARCHY_BLUETOOTH_DRIVER_DIR="$driver" \
    OMARCHY_BLUETOOTH_CLASS_DIR="$class" \
    bash "$fix" </dev/null
}

rebound() {
  [[ $(cat "$driver/unbind") == "$device" && $(cat "$driver/bind") == "$device" ]]
}

WEDGE_LINES=0 run_fix >/dev/null
rebound && fail "a healthy controller is left alone"
pass "no tx timeouts after resume leaves the controller alone"

WEDGE_LINES=3 run_fix >/dev/null
rebound || fail "a wedged controller is rebound" "unbind=$(cat "$driver/unbind") bind=$(cat "$driver/bind")"
pass "tx timeouts after resume rebind the controller"

# The kernel logs "PM: suspend exit" only after device resume, behind the tx
# timeouts, so the read has to start from the suspend entry to see them.
grep -Fq 'PM: suspend entry' "$calls" ||
  fail "the journal read is anchored on the suspend entry" "$(cat "$calls")"
grep -Fq 'PM: suspend exit' "$calls" &&
  fail "the journal read never anchors on the exit marker" "$(cat "$calls")"
pass "the journal read starts at the suspend entry, ahead of the timeouts"

# The timeouts are flushed at resume and can already be in the journal before
# the service starts, which is why the read is anchored to a marker rather
# than to a cursor taken when the service starts.
output=$(WEDGE_LINES=3 run_fix)
[[ $output == *"0s after resume"* ]] ||
  fail "timeouts logged before the service started are still seen" "$output"
pass "timeouts flushed before the service starts are still seen"

# No suspend marker, so the command falls back to a --since window; a clock
# that stepped backwards across resume leaves it empty.
output=$(NO_SUSPEND_MARKER=1 SINCE_EMPTY=1 WEDGE_LINES=3 run_fix)
rebound && fail "an empty fallback window does not rebind on its own"
[[ $output == *"watching from now"* ]] ||
  fail "the fallback says it has no suspend marker to read from" "$output"
output=$(NO_SUSPEND_MARKER=1 WEDGE_LINES=3 run_fix)
rebound || fail "the fallback window still catches a wedge"
pass "a missing suspend marker falls back to a time window"

output=$(RADIO_SOFT=blocked WEDGE_LINES=3 run_fix)
rebound && fail "a radio the user turned off is left off"
[[ $output == *"soft blocked"* ]] || fail "a blocked radio says so" "$output"
output=$(RADIO_SOFT= WEDGE_LINES=3 run_fix)
rebound && fail "a machine with no Bluetooth radio does nothing"
pass "a blocked or absent radio is never rebound"

output=$(DEVICE_BOUND=0 WEDGE_LINES=3 run_fix)
[[ $output == *"nothing to rebind"* ]] ||
  fail "an unbound driver has nothing to rebind" "$output"
pass "an unbound driver is reported rather than guessed at"
