#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
led_root="$test_tmp/leds"
call_log="$test_tmp/calls"
mkdir -p "$mock_bin" "$led_root"
: >"$call_log"

cat >"$mock_bin/brightnessctl" <<'SH'
#!/bin/bash

printf 'brightnessctl %s\n' "$*" >>"$CALL_LOG"
device=""
operation=""
save=0
restore=0
while (( $# )); do
  case $1 in
    -d)
      device=$2
      shift 2
      ;;
    -sd)
      device=$2
      save=1
      shift 2
      ;;
    -rd)
      device=$2
      restore=1
      shift 2
      ;;
    max|get|set)
      operation=$1
      shift
      ;;
    *)
      value=$1
      shift
      ;;
  esac
done

state="$LED_ROOT/$device"
if [[ -n ${FAIL_BACKEND:-} && ( ${FAIL_BACKEND:-} == "$operation" || ${FAIL_BACKEND:-} == "all" ) ]]; then
  exit 17
fi
if (( save )); then
  [[ ${FAIL_BACKEND:-} != "save" ]] || exit 18
  cp "$state/brightness" "$state/saved"
fi
if (( restore )); then
  [[ ${FAIL_BACKEND:-} != "restore" ]] || exit 19
  cp "$state/saved" "$state/brightness"
  exit 0
fi
case $operation in
  max)
    cat "$state/max"
    ;;
  get)
    cat "$state/brightness"
    ;;
  set)
    [[ ${FAIL_BACKEND:-} != "write" ]] || exit 20
    if [[ $value == *% ]]; then
      percent=${value%%%}
      max=$(cat "$state/max")
      raw=$(( (percent * max + 50) / 100 ))
    else
      raw=$value
    fi
    printf '%s\n' "$raw" >"$state/brightness"
    ;;
  *)
    exit 21
    ;;
esac
SH

cat >"$mock_bin/omarchy-osd" <<'SH'
#!/bin/bash
printf 'omarchy-osd %s\n' "$*" >>"$CALL_LOG"
[[ ${FAIL_OSD:-0} == 1 ]] && exit 22
SH
chmod +x "$mock_bin/brightnessctl" "$mock_bin/omarchy-osd"

reset_fixture() {
  rm -rf "$led_root"
  mkdir -p "$led_root/kbd_backlight-a"
  printf '%s\n' 255 >"$led_root/kbd_backlight-a/max"
  printf '%s\n' 128 >"$led_root/kbd_backlight-a/brightness"
  printf '%s\n' 64 >"$led_root/kbd_backlight-a/saved"
  : >"$call_log"
}

run_brightness() {
  CALL_LOG="$call_log" LED_ROOT="$led_root" OMARCHY_KEYBOARD_LED_ROOT="$led_root" \
    PATH="$mock_bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-brightness-keyboard" "$@"
}

run_brightness_unset_root() {
  CALL_LOG="$call_log" LED_ROOT="$led_root" PATH="$mock_bin:$ROOT/bin:$PATH" \
    env -u OMARCHY_KEYBOARD_LED_ROOT "$ROOT/bin/omarchy-brightness-keyboard" "$@"
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local description="$3"
  [[ $actual == "$expected" ]] || fail "$description" "expected: $expected\nactual: $actual"
  pass "$description"
}

assert_log_has() {
  local expected="$1"
  local description="$2"
  grep -F -- "$expected" "$call_log" >/dev/null || fail "$description" "missing: $expected"
  pass "$description"
}

assert_no_backend() {
  local description="$1"
  [[ ! -s $call_log ]] || fail "$description" "calls: $(cat "$call_log")"
  pass "$description"
}

invoke() {
  result=""
  if run_brightness "$@" >"$test_tmp/stdout" 2>"$test_tmp/stderr"; then
    status=0
  else
    status=$?
  fi
  result=$(cat "$test_tmp/stdout")
  error=$(cat "$test_tmp/stderr")
}

assert_status() {
  local expected="$1"
  local description="$2"
  [[ $status == "$expected" ]] || fail "$description" "expected status: $expected\nactual status: $status\nstdout: $result\nstderr: $error\ncalls: $(cat "$call_log")"
  pass "$description"
}

assert_output() {
  local expected="$1"
  local description="$2"
  [[ $result == "$expected" ]] || fail "$description" "expected output: $expected\nactual output: $result"
  pass "$description"
}

assert_output_contains() {
  local expected="$1"
  local description="$2"
  [[ $result == *"$expected"* || $error == *"$expected"* ]] || fail "$description" "missing output: $expected\nstdout: $result\nstderr: $error"
  pass "$description"
}

assert_file() {
  local path="$1"
  local expected="$2"
  local description="$3"
  actual=$(cat "$path")
  assert_eq "$actual" "$expected" "$description"
}

reset_fixture
invoke get
assert_status 0 "get reports the nearest percentage"
assert_output 50 "get output is exactly one percentage"
if grep -F 'omarchy-osd' "$call_log" >/dev/null || grep -F ' set ' "$call_log" >/dev/null; then
  fail "get performs no write or OSD"
fi
pass "get performs no write or OSD"

reset_fixture
invoke available
assert_status 0 "available detects the fixture device"
assert_no_backend "available performs no backend calls"

rm -rf "$led_root"
mkdir -p "$led_root"
: >"$call_log"
invoke available
assert_status 1 "available rejects a missing device"
assert_output_contains "No keyboard backlight device found" "missing device has a diagnostic"
assert_no_backend "missing available performs no backend calls"
invoke get
assert_status 1 "get rejects a missing device"
assert_no_backend "missing get performs no backend calls"
invoke set 50
assert_status 1 "set rejects a missing device"
assert_no_backend "missing set performs no backend calls"

: >"$call_log"
if result=$(run_brightness_unset_root available 2>"$test_tmp/stderr"); then
  status=0
else
  status=$?
fi
error=$(cat "$test_tmp/stderr")
[[ $status == 0 || $status == 1 ]] || fail "unset root available has a capability status" "status: $status\nstderr: $error"
assert_no_backend "unset root available performs no backend calls"
pass "unset root available has a safe status"

reset_fixture
mkdir -p "$led_root/kbd_backlight-z"
printf '%s\n' 255 >"$led_root/kbd_backlight-z/max"
printf '%s\n' 200 >"$led_root/kbd_backlight-z/brightness"
: >"$call_log"
invoke available
assert_status 0 "available accepts multiple matching devices"
assert_no_backend "multiple-device available performs no backend calls"
invoke get
assert_status 0 "multiple devices use the deterministic first match"
assert_output 50 "first matching device supplies the read"
assert_log_has "brightnessctl -d kbd_backlight-a max" "first matching device is selected"

reset_fixture
printf '%s\n' 1 >"$led_root/kbd_backlight-a/brightness"
invoke get
assert_status 0 "zero-ish raw value can be read"
assert_output 0 "low raw value rounds to zero"
printf '%s\n' 255 >"$led_root/kbd_backlight-a/brightness"
invoke get
assert_output 100 "maximum raw value reads as one hundred"
printf '%s\n' 127 >"$led_root/kbd_backlight-a/brightness"
invoke get
assert_output 50 "nearest conversion rounds half upward"

reset_fixture
invoke set 50
assert_status 0 "set accepts an integer percentage"
assert_log_has "brightnessctl -d kbd_backlight-a set 50%" "set uses the percentage backend"
assert_file "$led_root/kbd_backlight-a/brightness" 128 "set quantizes the raw fixture state"
invoke get
assert_output 50 "set followed by get reports quantized state"
: >"$call_log"
invoke --no-osd set 100
assert_status 0 "no-osd set succeeds"
assert_log_has "brightnessctl -d kbd_backlight-a set 100%" "no-osd set reaches the backend"
if grep -F 'omarchy-osd' "$call_log" >/dev/null; then
  fail "no-osd set does not emit OSD"
fi
pass "no-osd set does not emit OSD"
invoke --no-osd set 100
assert_status 0 "repeated set succeeds"
assert_file "$led_root/kbd_backlight-a/brightness" 255 "repeated set keeps the logical level"

reset_fixture
for invalid in -1 101 1.5 junk; do
  : >"$call_log"
  invoke set "$invalid"
  assert_status 2 "set rejects invalid value $invalid"
  assert_no_backend "invalid value $invalid is rejected before backend"
done
invoke set
assert_status 2 "set rejects a missing value"
assert_no_backend "missing set value reaches no backend"
invoke set 50 extra
assert_status 2 "set rejects extra arguments"
assert_no_backend "extra set argument reaches no backend"
invoke set 50 --no-osd
assert_status 2 "set rejects a trailing no-osd"
assert_no_backend "trailing no-osd reaches no backend"

reset_fixture
invoke --no-osd
assert_status 0 "bare no-osd retains the up default"
assert_file "$led_root/kbd_backlight-a/brightness" 153 "bare no-osd applies one ten-percent step"
if grep -F 'omarchy-osd' "$call_log" >/dev/null; then
  fail "bare no-osd suppresses OSD"
fi
pass "bare no-osd suppresses OSD"
: >"$call_log"
invoke --no-osd --no-osd set 50
assert_status 2 "duplicated no-osd is rejected"
assert_no_backend "duplicated no-osd reaches no backend"
invoke up --no-osd
assert_status 2 "misplaced no-osd is rejected"
assert_no_backend "misplaced no-osd reaches no backend"
invoke --no-osd get
assert_status 2 "no-osd is restricted to writes and legacy actions"
assert_no_backend "non-set no-osd reaches no backend"

reset_fixture
: >"$call_log"
invoke
assert_status 0 "no arguments retain the up default"
assert_file "$led_root/kbd_backlight-a/brightness" 153 "the default action applies one ten-percent step"
reset_fixture
invoke up
assert_status 0 "up succeeds"
assert_file "$led_root/kbd_backlight-a/brightness" 153 "up applies one ten-percent step"
assert_log_has "omarchy-osd -i keyboard -p 60" "up emits the keyboard OSD"
reset_fixture
invoke --no-osd down
assert_status 0 "no-osd down succeeds"
assert_file "$led_root/kbd_backlight-a/brightness" 103 "down applies one ten-percent step"
if grep -F 'omarchy-osd' "$call_log" >/dev/null; then
  fail "no-osd down does not emit OSD"
fi
pass "no-osd down does not emit OSD"
reset_fixture
printf '%s\n' 250 >"$led_root/kbd_backlight-a/brightness"
invoke cycle
assert_status 0 "cycle succeeds"
assert_file "$led_root/kbd_backlight-a/brightness" 0 "cycle wraps from the top to zero"
reset_fixture
invoke off
assert_status 0 "off succeeds"
assert_file "$led_root/kbd_backlight-a/saved" 128 "off saves the current level"
assert_file "$led_root/kbd_backlight-a/brightness" 0 "off writes zero"
assert_log_has "brightnessctl -sd kbd_backlight-a set 0" "off uses the exact saved-zero backend call"
if grep -F 'omarchy-osd' "$call_log" >/dev/null; then
  fail "off does not emit OSD"
fi
pass "off does not emit OSD"
invoke restore
assert_status 0 "restore succeeds"
assert_file "$led_root/kbd_backlight-a/brightness" 128 "restore recovers the saved level"
assert_log_has "brightnessctl -rd kbd_backlight-a" "restore uses the exact saved-state backend call"
if grep -F 'omarchy-osd' "$call_log" >/dev/null; then
  fail "restore does not emit OSD"
fi
pass "restore does not emit OSD"
reset_fixture
invoke --no-osd off
assert_status 0 "no-osd remains accepted for off"
reset_fixture
invoke --no-osd restore
assert_status 0 "no-osd remains accepted for restore"
invoke nonsense
assert_status 2 "unknown action is rejected"

reset_fixture
export FAIL_BACKEND=get
invoke get
unset FAIL_BACKEND
assert_status 1 "get backend failure propagates"
if grep -F 'omarchy-osd' "$call_log" >/dev/null; then
  fail "get failure does not emit OSD"
fi
pass "get failure does not emit OSD"
reset_fixture
export FAIL_BACKEND=max
invoke get
unset FAIL_BACKEND
assert_status 1 "maximum read failure propagates"
reset_fixture
export FAIL_BACKEND=write
invoke set 50
unset FAIL_BACKEND
assert_status 1 "set backend failure propagates"
if grep -F 'omarchy-osd' "$call_log" >/dev/null; then
  fail "set failure does not emit OSD"
fi
pass "set failure does not emit OSD"
reset_fixture
export FAIL_BACKEND=write
invoke up
unset FAIL_BACKEND
assert_status 1 "step write failure propagates"
if grep -F 'omarchy-osd' "$call_log" >/dev/null; then
  fail "step write failure does not emit OSD"
fi
pass "step write failure does not emit OSD"
reset_fixture
export FAIL_BACKEND=write
invoke down
unset FAIL_BACKEND
assert_status 1 "down write failure propagates"
reset_fixture
export FAIL_BACKEND=write
invoke cycle
unset FAIL_BACKEND
assert_status 1 "cycle write failure propagates"
reset_fixture
export FAIL_BACKEND=save
invoke off
unset FAIL_BACKEND
assert_status 1 "off save failure propagates"
assert_file "$led_root/kbd_backlight-a/brightness" 128 "off save failure leaves brightness unchanged"
if grep -F 'omarchy-osd' "$call_log" >/dev/null; then
  fail "off save failure does not emit OSD"
fi
pass "off save failure does not emit OSD"
reset_fixture
export FAIL_BACKEND=write
invoke off
unset FAIL_BACKEND
assert_status 1 "off write failure propagates"
assert_file "$led_root/kbd_backlight-a/brightness" 128 "off write failure leaves brightness unchanged"
reset_fixture
export FAIL_BACKEND=restore
invoke restore
unset FAIL_BACKEND
assert_status 1 "restore failure propagates"

reset_fixture
export FAIL_OSD=1
invoke set 50
unset FAIL_OSD
assert_status 0 "OSD failure retains successful hardware status"
assert_output_contains "brightness write succeeded but OSD failed" "OSD failure is an explicit warning"
[[ -z $result && $error == *"brightness write succeeded but OSD failed"* ]] || fail "OSD warning is written to stderr" "stdout: $result\nstderr: $error"
pass "OSD warning is written to stderr"
assert_file "$led_root/kbd_backlight-a/brightness" 128 "OSD failure does not undo the hardware write"
reset_fixture
export FAIL_OSD=1
invoke up
unset FAIL_OSD
assert_status 0 "legacy step keeps hardware success when OSD fails"
assert_output_contains "brightness write succeeded but OSD failed" "legacy OSD failure is an explicit warning"
[[ -z $result && $error == *"brightness write succeeded but OSD failed"* ]] || fail "legacy OSD warning is written to stderr" "stdout: $result\nstderr: $error"
pass "legacy OSD warning is written to stderr"

reset_fixture
invoke set 0
assert_status 0 "set accepts zero percent"
assert_file "$led_root/kbd_backlight-a/brightness" 0 "zero percent writes zero raw brightness"
reset_fixture
invoke --no-osd set 1
assert_status 0 "set accepts one percent"
invoke get
assert_output 1 "one percent survives percentage quantization"

reset_fixture
printf '%s\n' 90000000000000000 >"$led_root/kbd_backlight-a/max"
printf '%s\n' 90000000000000000 >"$led_root/kbd_backlight-a/brightness"
invoke get
assert_status 0 "the safe brightness boundary is accepted"
assert_output 100 "the safe brightness boundary converts without overflow"
printf '%s\n' 90000000000000001 >"$led_root/kbd_backlight-a/max"
invoke get
assert_status 1 "maximum above the safe boundary fails"
reset_fixture
printf '%s\n' 90000000000000001 >"$led_root/kbd_backlight-a/brightness"
invoke get
assert_status 1 "current above the safe boundary fails"
reset_fixture
printf '%s\n' 999999999999999999999999999999 >"$led_root/kbd_backlight-a/max"
invoke get
assert_status 1 "huge maximum fails before arithmetic"

reset_fixture
rm -f "$led_root/kbd_backlight-a/max"
invoke get
assert_status 1 "missing maximum fails"
reset_fixture
printf '%s\n' 0 >"$led_root/kbd_backlight-a/max"
invoke get
assert_status 1 "zero maximum fails"
reset_fixture
printf '%s\n' invalid >"$led_root/kbd_backlight-a/brightness"
invoke get
assert_status 1 "malformed current value fails"
reset_fixture
printf '%s\n' invalid >"$led_root/kbd_backlight-a/max"
invoke get
assert_status 1 "malformed maximum fails"
reset_fixture
printf '%s\n' 300 >"$led_root/kbd_backlight-a/brightness"
invoke get
assert_status 0 "current values above maximum remain readable"
assert_output 100 "percentage output is clamped to one hundred"

if [[ $(sed -n '1,8p' "$ROOT/bin/omarchy-brightness-keyboard") != *"omarchy:args=[--no-osd] <available|get|set <0-100>|up|down|cycle|off|restore>"* ]]; then
  fail "command metadata advertises the complete CLI"
fi
pass "command metadata advertises the complete CLI"
if grep -F '/sys/class/leds' "$ROOT/bin/omarchy-brightness-keyboard" >/dev/null; then
  pass "production keeps the default sysfs root"
else
  fail "production keeps the default sysfs root"
fi
