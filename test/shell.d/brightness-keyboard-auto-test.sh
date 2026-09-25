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

migration=$(ls "$ROOT"/migrations/*keyboard*als* "$ROOT"/migrations/*als*keyboard* 2>/dev/null | tail -n 1 || true)
if [[ -z $migration ]]; then
  migration=$(grep -l omarchy-brightness-keyboard-auto.service "$ROOT"/migrations/*.sh | tail -n 1 || true)
fi
[[ -n $migration ]] || fail "a migration enables the ALS keyboard backlight unit"
grep -F 'omarchy-brightness-keyboard-auto.service' "$migration" >/dev/null
grep -F 'systemctl --user enable' "$migration" >/dev/null
grep -F '/usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service' "$migration" >/dev/null ||
  fail "migration does not enable the package-owned unit"
grep -e 'cp .*omarchy-brightness-keyboard-auto.service' "$migration" >/dev/null &&
  fail "migration copies the unit into ~/.config/systemd/user"
pass "migration enables ambient keyboard backlight for existing installs"

# Drive the real keyboard-brightness command and the loop's tick against a fake
# sensor and LED, the way lock blanking, wake restore and the keys interleave.
loop=$(mktemp -d)
trap 'rm -rf "$fake" "$leds" "$loop"' EXIT
mkdir -p "$loop/iio/iio:device1" "$loop/leds/kbd_backlight" "$loop/bin" "$loop/runtime"
printf 'aop-sensors-als\n' >"$loop/iio/iio:device1/name"
printf '26\n' >"$loop/iio/iio:device1/in_illuminance_input"
printf '255\n' >"$loop/leds/kbd_backlight/max_brightness"
printf '0\n' >"$loop/leds/kbd_backlight/brightness"

cat >"$loop/bin/brightnessctl" <<'SH'
#!/bin/bash
save=0
restore=0
device=""
while (( $# )); do
  case $1 in
    -sd) save=1; device=$2; shift 2 ;;
    -rd) restore=1; device=$2; shift 2 ;;
    -d) device=$2; shift 2 ;;
    -m) shift ;;
    *) break ;;
  esac
done
led="$OMARCHY_LEDS_DIR/$device"
if (( restore )); then
  cp "$led/saved" "$led/brightness"
  exit 0
fi
case ${1:-} in
  get) cat "$led/brightness" ;;
  max) cat "$led/max_brightness" ;;
  set)
    (( ! save )) || cp "$led/brightness" "$led/saved"
    printf '%s\n' "$2" >"$led/brightness"
    ;;
esac
SH
cat >"$loop/bin/omarchy-hyprland-session-locked" <<'SH'
#!/bin/bash
[[ ${LOCKED:-0} == "1" ]]
SH
cat >"$loop/bin/omarchy-hw-laptop-closed" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$loop/bin/"*

export PATH="$loop/bin:$PATH" OMARCHY_LEDS_DIR="$loop/leds" XDG_RUNTIME_DIR="$loop/runtime"
eval "$(grep -E '^(DARK_LUX|BRIGHT_LUX|DEADBAND_PERCENT|OVERRIDE_LUX_DELTA|OVERRIDE_LUX_RATIO|EFFECTIVELY_OFF_PERCENT|MANUAL_LEVEL_FILE)=' "$auto")"
for fn in lux_to_percent read_lux session_locked lid_closed apply_percent left_off tick; do
  eval "$(sed -n "/^$fn()/,/^}/p" "$auto")"
done
als_path="$loop/iio/iio:device1/in_illuminance_input"
device=kbd_backlight
max=255
last_set=""
paused=0
pause_lux=0

keys() { "$ROOT/bin/omarchy-brightness-keyboard" --no-osd "$1"; }
led() { cat "$loop/leds/kbd_backlight/brightness"; }
lux() { printf '%s\n' "$1" >"$als_path"; }

tick
(( $(led) == 226 )) || fail "a dark room lights the keys" "got $(led)"
keys off
LOCKED=1 tick
(( $(led) == 0 )) || fail "a locked session keeps the keys blank" "got $(led)"
tick
(( $(led) == 226 )) || fail "keys left blank after unlock light up again" "got $(led)"
printf '2\n' >"$loop/leds/kbd_backlight/brightness"
tick
(( $(led) == 226 )) || fail "a 1% leftover lights up again" "got $(led)"
pass "keys left off by lock blanking or a leftover light up again with the room"

until (( $(led) == 0 )); do
  keys down
  tick
done
tick
(( $(led) == 0 )) || fail "keys turned off with the brightness keys stay off" "got $(led)"
keys off
LOCKED=1 tick
keys restore
tick
(( $(led) == 0 )) || fail "a deliberate off survives lock and wake" "got $(led)"
lux 150
tick
(( $(led) == 43 )) || fail "a deliberate off resumes once the room changes enough" "got $(led)"
keys off
tick
(( $(led) == 43 )) || fail "after auto resumes, a lock blank is a leftover again" "got $(led)"
pass "keys turned off by hand stay off until the room changes enough"

keys up
tick
tick
(( $(led) == 68 )) || fail "a visible level set by hand still pauses auto" "got $(led)"
pass "a visible level set by hand still pauses automatic control"

lux 26
tick
until (( $(led) == 0 )); do
  keys down
  tick
done
printf '2\n' >"$loop/leds/kbd_backlight/brightness"
tick
(( $(led) == 226 )) || fail "a leftover after a deliberate off lights up again" "got $(led)"
keys off
tick
(( $(led) == 226 )) || fail "a relit leftover forgets the earlier deliberate off" "got $(led)"
pass "a relit leftover forgets the earlier deliberate off"
