#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

auto="$ROOT/bin/omarchy-brightness-keyboard-auto"

[[ -x $auto ]] || fail "omarchy-brightness-keyboard-auto is executable"

map_lux() {
  "$auto" --map-lux "$1"
}

[[ $(map_lux 0) == 100 ]] || fail "pitch dark lights the keyboard fully" "got $(map_lux 0)"
[[ $(map_lux 8) == 100 ]] || fail "dim indoor still uses full keyboard light" "got $(map_lux 8)"
[[ $(map_lux 94) == 50 ]] || fail "mid lux maps to half keyboard light" "got $(map_lux 94)"
[[ $(map_lux 180) == 0 ]] || fail "bright room turns the keyboard light off" "got $(map_lux 180)"
[[ $(map_lux 400) == 0 ]] || fail "daylight keeps the keyboard light off" "got $(map_lux 400)"
pass "ambient lux maps inversely onto keyboard backlight"

if ! "$auto" --map-lux >/dev/null 2>&1; then
  pass "map-lux without a value is an error"
else
  fail "map-lux without a value should fail"
fi

grep -F 'Drive keyboard backlight from the ambient light sensor' "$auto" >/dev/null
pass "auto helper declares command metadata"

grep -F 'POLL_SECONDS=5' "$auto" >/dev/null || fail "ALS keyboard loop still wakes every second"
pass "ALS keyboard loop polls every 5 seconds"

grep -F 'exit $?' "$auto" >/dev/null &&
  fail "--available still relies on set -e to turn a failed [[ ]] into the exit status"
pass "--available uses an explicit if/else exit"

eval "$(sed -n '/^find_als()/,/^}/p' "$auto")"

fake=$(mktemp -d)
leds=$(mktemp -d)
trap 'rm -rf "$fake" "$leds"' EXIT
mkdir -p "$fake/iio:device0" "$fake/iio:device1" "$fake/iio:device2"

printf 'aop-sensors-las\n' >"$fake/iio:device0/name"
printf '12\n' >"$fake/iio:device0/in_illuminance_raw"
printf 'aop-sensors-als\n' >"$fake/iio:device1/name"
printf '23\n' >"$fake/iio:device1/in_illuminance_input"
printf 'ambient-light\n' >"$fake/iio:device2/name"
printf '40\n' >"$fake/iio:device2/in_illuminance_input"

got=$(OMARCHY_IIO_DEVICES_DIR=$fake find_als)
[[ $got == "$fake/iio:device1/in_illuminance_input" ]] ||
  fail "find_als prefers a device whose name contains als" "got $got"
pass "find_als prefers a named ALS device over an earlier illuminance channel"

rm -r "$fake/iio:device1"
got=$(OMARCHY_IIO_DEVICES_DIR=$fake find_als)
[[ $got == "$fake/iio:device0/in_illuminance_raw" ]] ||
  fail "find_als falls back to the first readable illuminance channel" "got $got"
pass "find_als falls back when no device name contains als"

mkdir -p "$leds/kbd_backlight"
printf '255\n' >"$leds/kbd_backlight/max_brightness"
printf '0\n' >"$leds/kbd_backlight/brightness"

if OMARCHY_IIO_DEVICES_DIR=$fake OMARCHY_LEDS_DIR=$leds "$auto" --available; then
  pass "--available succeeds when both ALS and keyboard LED are present"
else
  fail "--available should succeed when both ALS and keyboard LED are present"
fi

rm -r "$leds/kbd_backlight"
if OMARCHY_IIO_DEVICES_DIR=$fake OMARCHY_LEDS_DIR=$leds "$auto" --available; then
  fail "--available should fail when the keyboard LED is missing"
else
  pass "--available fails when the keyboard LED is missing"
fi

manual="$ROOT/manual/34-keyboard-mouse-trackpad.md"
grep -F 'Lock and lid-close keep the keys off' "$manual" >/dev/null &&
  fail "manual still claims lock and lid-close turn the keys off"
grep -F 'Automatic control pauses while the screen is locked or the lid is closed' "$manual" >/dev/null ||
  fail "manual does not describe lock and lid-close as a pause"
pass "manual describes lock and lid-close as pausing automatic control"

# These checks cover the original rollout. Later repairs have their own
# behavioral tests and need not use the original migration's literal syntax.
migration="$ROOT/migrations/1788139121.sh"
[[ -f $migration ]] || fail "the original migration enables the ALS keyboard backlight unit"
grep -F 'omarchy-brightness-keyboard-auto.service' "$migration" >/dev/null
grep -F 'systemctl --user enable' "$migration" >/dev/null
grep -F '/usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service' "$migration" >/dev/null ||
  fail "migration does not enable the package-owned unit"
grep -e 'cp .*omarchy-brightness-keyboard-auto.service' "$migration" >/dev/null &&
  fail "migration copies the unit into ~/.config/systemd/user"
pass "migration enables ambient keyboard backlight for existing installs"

# Drive the daemon's real decision logic one poll at a time: its tunables and
# tick path are loaded here, and every LED write goes through the real
# omarchy-brightness-keyboard key, lock-blank and restore paths.
tick_tmp=$(mktemp -d)
trap 'rm -rf "$fake" "$leds" "$tick_tmp"' EXIT

export XDG_RUNTIME_DIR="$tick_tmp/run"
export OMARCHY_LEDS_DIR="$tick_tmp/leds"
eval "$(grep -E '^[A-Z_]+=[0-9]+$|^manual_file=' "$auto")"
for fn in lux_to_percent led_effectively_off last_key_turned_off read_lux session_locked lid_closed apply_percent tick; do
  eval "$(sed -n "/^$fn()/,/^}/p" "$auto")"
done
[[ -n ${manual_file:-} ]] || fail "the daemon defines where key presses are recorded"

max=255
led_effectively_off 0 || fail "0 is effectively off"
led_effectively_off 5 || fail "5/255 (2%) is effectively off"
if led_effectively_off 6; then
  fail "6/255 is above the effectively-off band"
fi
pass "the LED counts as off up to 2% of max"

stub="$tick_tmp/bin"
mkdir -p "$XDG_RUNTIME_DIR" "$OMARCHY_LEDS_DIR/kbd_backlight" "$tick_tmp/iio/iio:device0" "$stub"
printf 'aop-sensors-als\n' >"$tick_tmp/iio/iio:device0/name"
printf '255\n' >"$OMARCHY_LEDS_DIR/kbd_backlight/max_brightness"
printf '0\n' >"$OMARCHY_LEDS_DIR/kbd_backlight/brightness"

# brightnessctl over the fake LED; -s saves the level and -r restores it.
cat >"$stub/brightnessctl" <<'SH'
#!/bin/bash
save=0
restore=0
while (($#)); do
  case "$1" in
    -*d)
      [[ $1 == *s* ]] && save=1
      [[ $1 == *r* ]] && restore=1
      led="$OMARCHY_LEDS_DIR/$2"
      shift 2
      ;;
    get) exec cat "$led/brightness" ;;
    max) exec cat "$led/max_brightness" ;;
    set)
      (( save )) && cp "$led/brightness" "$led/saved"
      printf '%s\n' "$2" >"$led/brightness"
      exit 0
      ;;
    *) shift ;;
  esac
done
(( restore )) && cp "$led/saved" "$led/brightness"
exit 0
SH

cat >"$stub/omarchy-hyprland-session-locked" <<'SH'
#!/bin/bash
exit "${SESSION_LOCKED:-1}"
SH

cat >"$stub/omarchy-hw-laptop-closed" <<'SH'
#!/bin/bash
exit 1
SH

chmod +x "$stub"/*
export PATH="$stub:$PATH"

als_path="$tick_tmp/iio/iio:device0/in_illuminance_input"
device=kbd_backlight
last_set=""
paused=0
pause_lux=0

set_lux() {
  printf '%s\n' "$1" >"$als_path"
}

led() {
  cat "$OMARCHY_LEDS_DIR/kbd_backlight/brightness"
}

keyboard() {
  "$ROOT/bin/omarchy-brightness-keyboard" --no-osd "$1"
}

# Lock and let the lock screen blank the keys, then unlock. The unlock poll can
# land before the wake-up restore runs, or no restore comes at all.
lock_blank_unlock() {
  keyboard off
  SESSION_LOCKED=0 tick
  [[ $(led) == 0 ]] || fail "ALS leaves the keys alone while the session is locked" "got $(led)"
  tick
}

# Naming a variable that is set, a record would run commands if evaluated.
printf 'max[$(touch %s)]\n' "$tick_tmp/injected" >"$manual_file"
if ( last_key_turned_off ); then
  fail "a non-numeric key-press record counts as a key press"
fi
[[ ! -e $tick_tmp/injected ]] || fail "the key-press record was evaluated as arithmetic"
rm "$manual_file"
pass "the key-press record is read as a number and never evaluated"

# 26 lux is a dim room: ALS wants 89%, 226/255.
set_lux 26
tick
[[ $(led) == 226 ]] || fail "first poll lights the keys from ALS" "got $(led)"

lock_blank_unlock
[[ $(led) == 226 ]] || fail "a lock blank left behind after unlock is relit from ALS" "got $(led)"
(( paused == 0 )) || fail "a lock blank does not pause ALS"
pass "a lock-screen blank does not leave the keys dark after unlock"

printf '2\n' >"$OMARCHY_LEDS_DIR/kbd_backlight/saved"
keyboard restore
tick
[[ $(led) == 226 ]] || fail "a restored 1% save is relit from ALS" "got $(led)"
pass "a saved near-zero backlight restore does not leave the keys dark"

# Stepping down from 226 stops at 1/255: dark, and the OSD already reads 0%.
until led_effectively_off "$(led)"; do
  keyboard down
done
[[ $(led) == 1 ]] || fail "stepping down from 226 lands on 1" "got $(led)"
# Lock before the next poll: the first level ALS sees is the blank's 0.
lock_blank_unlock
[[ $(led) == 0 ]] || fail "a lock blank does not relight keys turned off by hand" "got $(led)"
(( paused == 1 )) || fail "turning the keys off by hand pauses ALS"
keyboard restore
tick
[[ $(led) == 1 ]] || fail "keys turned off by hand stay off through lock and wake" "got $(led)"
set_lux 0
tick
[[ $(led) == 1 ]] || fail "keys turned off by hand stay off when the room goes dark" "got $(led)"
pass "keys turned off by hand stay off through lock, wake and room light changes"

keyboard up
tick
[[ $(led) == 26 ]] || fail "the next key press is kept" "got $(led)"
(( paused == 1 )) || fail "a visible key-press level pauses ALS"
set_lux 8
tick
[[ $(led) == 26 ]] || fail "a visible key-press level holds while the room light is stable" "got $(led)"
set_lux 26
tick
[[ $(led) == 226 ]] || fail "ALS resumes once the room light moves past the old choice" "got $(led)"
pass "the next key press ends the hold, and ALS resumes when the room light moves"

# Down at 0 on the blanked lock screen changes nothing, so it must not make a
# later blank look deliberate.
keyboard off
keyboard down
keyboard restore
tick
lock_blank_unlock
[[ $(led) == 226 ]] || fail "a key press that changed nothing made a later lock blank look deliberate" "got $(led)"
pass "a key press that changes nothing is not taken for a deliberate off"

until (( $(led) == 0 )); do
  keyboard down
done
tick
brightnessctl -d kbd_backlight set 128
tick
[[ $(led) == 128 ]] || fail "a visible level from another tool is kept" "got $(led)"
(( paused == 1 )) || fail "a visible level from another tool pauses ALS"
pass "a visible level from another tool still pauses ALS"

# ALS writing the keys again ends the old deliberate off: a later lock blank is
# not that choice coming back.
set_lux 0
tick
[[ $(led) == 255 ]] || fail "ALS resumes once the room light moves past the other tool's level" "got $(led)"
lock_blank_unlock
[[ $(led) == 255 ]] || fail "an old deliberate off made a later lock blank look deliberate" "got $(led)"
pass "once ALS has written the keys again, an old deliberate off does not come back"

# A debug --once run leaves a live key press alone. The daemon itself starts by
# applying ALS, so it drops any key press from before it ran.
export OMARCHY_IIO_DEVICES_DIR="$tick_tmp/iio"
printf '0\n' >"$manual_file"
"$auto" --once
[[ -e $manual_file ]] || fail "--once dropped a live key press"
"$auto" >/dev/null 2>&1 &
daemon=$!
for _ in {1..50}; do
  [[ -e $manual_file ]] || break
  sleep 0.1
done
kill "$daemon" 2>/dev/null || true
wait "$daemon" 2>/dev/null || true
[[ ! -e $manual_file ]] || fail "the daemon kept a key press from before it started"
pass "the daemon drops key presses from before it started, --once leaves them"
