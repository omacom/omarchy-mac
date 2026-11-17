#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

auto="$ROOT/bin/omarchy-brightness-keyboard-auto"
work=$(mktemp -d)
stop_loop() {
  if [[ -n ${loop_pid:-} ]]; then
    kill "$loop_pid" 2>/dev/null || true
    wait "$loop_pid" 2>/dev/null || true
    loop_pid=""
  fi
}

trap 'stop_loop; rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/iio/iio:device0" "$work/leds/kbd_backlight"
printf '0\n' >"$work/clock"
printf '0\n' >"$work/release"
printf '0\n' >"$work/sleeps"
printf '0\n' >"$work/lock"
printf '0\n' >"$work/lid"
printf 'aop-sensors-als\n' >"$work/iio/iio:device0/name"
printf '0\n' >"$work/iio/iio:device0/in_illuminance_input"
printf '255\n' >"$work/leds/kbd_backlight/max_brightness"
printf '0\n' >"$work/leds/kbd_backlight/brightness"

cat >"$work/bin/date" <<'EOF'
#!/bin/bash
[[ $1 == "+%s" ]] || exit 1
tr -d '[:space:]' <"$OMARCHY_TEST_CLOCK"
EOF

cat >"$work/bin/sleep" <<'EOF'
#!/bin/bash
n=$(tr -d '[:space:]' <"$OMARCHY_TEST_SLEEPS")
printf '%s\n' "$((n + 1))" >"$OMARCHY_TEST_SLEEPS"
while [[ -f $OMARCHY_TEST_RELEASE ]] && [[ $(tr -d '[:space:]' <"$OMARCHY_TEST_RELEASE") -le $n ]]; do
  /bin/sleep 0.02
done
[[ -f $OMARCHY_TEST_CLOCK ]] || exit 0
clock=$(tr -d '[:space:]' <"$OMARCHY_TEST_CLOCK")
printf '%s\n' "$((clock + ${1%.*}))" >"$OMARCHY_TEST_CLOCK"
EOF

cat >"$work/bin/brightnessctl" <<'EOF'
#!/bin/bash
device=""
while (($#)); do
  case "$1" in
    -d) device=$2; shift 2 ;;
    get)
      tr -d '[:space:]' <"$OMARCHY_TEST_BRIGHTNESS"
      exit 0
      ;;
    set)
      printf '%s\n' "$2" >"$OMARCHY_TEST_BRIGHTNESS"
      exit 0
      ;;
    *) exit 1 ;;
  esac
done
exit 1
EOF

cat >"$work/bin/omarchy-hyprland-session-locked" <<'EOF'
#!/bin/bash
[[ $(tr -d '[:space:]' <"$OMARCHY_TEST_LOCK") == 1 ]]
EOF

cat >"$work/bin/omarchy-hw-laptop-closed" <<'EOF'
#!/bin/bash
[[ $(tr -d '[:space:]' <"$OMARCHY_TEST_LID") == 1 ]]
EOF

chmod +x "$work/bin/"*

export OMARCHY_TEST_CLOCK="$work/clock"
export OMARCHY_TEST_RELEASE="$work/release"
export OMARCHY_TEST_SLEEPS="$work/sleeps"
export OMARCHY_TEST_LOCK="$work/lock"
export OMARCHY_TEST_LID="$work/lid"
export OMARCHY_TEST_BRIGHTNESS="$work/leds/kbd_backlight/brightness"
export OMARCHY_IIO_DEVICES_DIR="$work/iio"
export OMARCHY_LEDS_DIR="$work/leds"
export PATH="$work/bin:$PATH"

brightness() {
  tr -d '[:space:]' <"$OMARCHY_TEST_BRIGHTNESS"
}

wait_for_sleeps() {
  local want=$1
  local i
  for ((i = 0; i < 200; i++)); do
    [[ $(tr -d '[:space:]' <"$OMARCHY_TEST_SLEEPS") -ge $want ]] && return 0
    /bin/sleep 0.02
  done
  fail "keyboard auto loop did not reach sleep $want" "sleeps=$(<"$OMARCHY_TEST_SLEEPS") brightness=$(brightness)"
}

release_sleep() {
  local n
  n=$(tr -d '[:space:]' <"$OMARCHY_TEST_RELEASE")
  printf '%s\n' "$((n + 1))" >"$OMARCHY_TEST_RELEASE"
}

start_loop() {
  "$auto" &
  loop_pid=$!
  wait_for_sleeps 1
  [[ $(brightness) == 255 ]] || fail "pitch dark lights the keys on the first poll" "got $(brightness)"
}

start_loop
pass "pitch dark lights the keys on the first poll"

printf '0\n' >"$OMARCHY_TEST_BRIGHTNESS"
release_sleep
wait_for_sleeps 2
[[ $(brightness) == 0 ]] || fail "a brightness-key change in steady dark stays put" "got $(brightness)"
pass "a brightness-key change in steady dark stays put"

kill "$loop_pid" 2>/dev/null || true
wait "$loop_pid" 2>/dev/null || true
loop_pid=""

printf '0\n' >"$work/clock"
printf '0\n' >"$work/release"
printf '0\n' >"$work/sleeps"
printf '0\n' >"$OMARCHY_TEST_BRIGHTNESS"
start_loop

printf '0\n' >"$OMARCHY_TEST_BRIGHTNESS"
printf '1060\n' >"$work/clock"
release_sleep
wait_for_sleeps 2
[[ $(brightness) == 255 ]] || fail "waking from suspend in the dark lights the keys again" "got $(brightness)"
pass "waking from suspend in the dark lights the keys again"

kill "$loop_pid" 2>/dev/null || true
wait "$loop_pid" 2>/dev/null || true
loop_pid=""

printf '0\n' >"$work/clock"
printf '0\n' >"$work/release"
printf '0\n' >"$work/sleeps"
printf '0\n' >"$OMARCHY_TEST_BRIGHTNESS"
start_loop

printf '1\n' >"$work/lock"
release_sleep
wait_for_sleeps 2
printf '0\n' >"$OMARCHY_TEST_BRIGHTNESS"
printf '0\n' >"$work/lock"
release_sleep
wait_for_sleeps 3
[[ $(brightness) == 255 ]] || fail "unlocking in the dark lights the keys again" "got $(brightness)"
pass "unlocking in the dark lights the keys again"
