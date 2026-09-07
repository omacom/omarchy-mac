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
