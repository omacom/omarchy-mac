#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

auto="$ROOT/bin/omarchy-brightness-keyboard-auto"

[[ -x $auto ]] || fail "omarchy-brightness-keyboard-auto is executable"

# A private HOME keeps the developer's own keyboard-backlight.conf out of the
# defaults under test; the runtime dir holds the loop's pid and idle flag.
test_home=$(mktemp -d)
runtime=$(mktemp -d)
fake=$(mktemp -d)
leds=$(mktemp -d)
mock_bin=$(mktemp -d)
loop_pid=""

cleanup() {
  [[ -n $loop_pid ]] && kill "$loop_pid" 2>/dev/null
  rm -rf "$test_home" "$runtime" "$fake" "$leds" "$mock_bin"
}
trap cleanup EXIT

config="$test_home/.config/omarchy/keyboard-backlight.conf"
mkdir -p "$(dirname "$config")"

run_auto() {
  HOME="$test_home" XDG_RUNTIME_DIR="$runtime" "$auto" "$@"
}

map_lux() {
  run_auto --map-lux "$1"
}

[[ $(map_lux 0) == 100 ]] || fail "pitch dark lights the keyboard fully" "got $(map_lux 0)"
[[ $(map_lux 8) == 100 ]] || fail "dim indoor still uses full keyboard light" "got $(map_lux 8)"
[[ $(map_lux 94) == 50 ]] || fail "mid lux maps to half keyboard light" "got $(map_lux 94)"
[[ $(map_lux 180) == 0 ]] || fail "bright room turns the keyboard light off" "got $(map_lux 180)"
[[ $(map_lux 400) == 0 ]] || fail "daylight keeps the keyboard light off" "got $(map_lux 400)"
pass "ambient lux maps inversely onto keyboard backlight"

if ! run_auto --map-lux >/dev/null 2>&1; then
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

cat >"$config" <<'CONF'
# thresholds for a dim office
DARK_LUX = 40
BRIGHT_LUX=80   # keys off from here up
IDLE_SECONDS=30
POLL_SECONDS=lots
CONF
[[ $(map_lux 40) == 100 ]] || fail "configured dark threshold gives full light" "got $(map_lux 40)"
[[ $(map_lux 60) == 50 ]] || fail "configured ramp midpoint gives half light" "got $(map_lux 60)"
[[ $(map_lux 80) == 0 ]] || fail "configured bright threshold turns the light off" "got $(map_lux 80)"
pass "keyboard-backlight.conf sets the lux thresholds"

[[ $(run_auto --idle-seconds) == 30 ]] || fail "keyboard-backlight.conf sets the idle timeout" "got $(run_auto --idle-seconds)"
pass "keyboard-backlight.conf sets the idle timeout"

rm "$config"
[[ $(run_auto --idle-seconds) == 10 ]] || fail "idle timeout defaults to ten seconds" "got $(run_auto --idle-seconds)"
pass "idle timeout defaults to ten seconds without a config"

printf 'DARK_LUX=200\nBRIGHT_LUX=100\n' >"$config"
[[ $(map_lux 94) == 50 ]] || fail "an inverted threshold pair falls back to the defaults" "got $(map_lux 94)"
pass "an inverted threshold pair falls back to the defaults"
rm "$config"

eval "$(sed -n '/^find_als()/,/^}/p' "$auto")"

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

if OMARCHY_IIO_DEVICES_DIR=$fake OMARCHY_LEDS_DIR=$leds run_auto --available; then
  pass "--available succeeds when both ALS and keyboard LED are present"
else
  fail "--available should succeed when both ALS and keyboard LED are present"
fi

rm -r "$leds/kbd_backlight"
if OMARCHY_IIO_DEVICES_DIR=$fake OMARCHY_LEDS_DIR=$leds run_auto --available; then
  fail "--available should fail when the keyboard LED is missing"
else
  pass "--available fails when the keyboard LED is missing"
fi

# The loop against a fake sensor and LED. brightnessctl reads and writes the
# fake LED; the lock and lid probes report an open, unlocked laptop.
mkdir -p "$fake/iio:device1"
printf 'aop-sensors-als\n' >"$fake/iio:device1/name"
als="$fake/iio:device1/in_illuminance_input"
led="$leds/kbd_backlight/brightness"
mkdir -p "$leds/kbd_backlight"
printf '255\n' >"$leds/kbd_backlight/max_brightness"
printf '0\n' >"$led"
printf '0\n' >"$als"

cat >"$mock_bin/brightnessctl" <<'SH'
#!/bin/bash
# brightnessctl -d <device> get | set <value>
led="$OMARCHY_LEDS_DIR/$2/brightness"
if [[ $3 == "get" ]]; then
  cat "$led"
else
  printf '%s\n' "$4" >"$led"
fi
SH
printf '#!/bin/bash\nexit 1\n' >"$mock_bin/omarchy-hyprland-session-locked"
printf '#!/bin/bash\nexit 1\n' >"$mock_bin/omarchy-hw-laptop-closed"
chmod +x "$mock_bin"/*

brightness() {
  cat "$led"
}

wait_for_brightness() {
  local expected=$1 attempt
  for attempt in $(seq 1 40); do
    [[ $(brightness) == "$expected" ]] && return 0
    sleep 0.1
  done
  return 1
}

# Long polls, so every change below is the USR1 from --idle and --active (or
# a poke standing in for a poll) doing the work, not the timer.
printf 'POLL_SECONDS=60\n' >"$config"
pid_file="$runtime/omarchy-keyboard-backlight/pid"
PATH="$mock_bin:$PATH" HOME="$test_home" XDG_RUNTIME_DIR="$runtime" \
  OMARCHY_IIO_DEVICES_DIR=$fake OMARCHY_LEDS_DIR=$leds "$auto" &
loop_pid=$!

wait_for_brightness 255 || fail "the loop lights the keys in the dark" "got $(brightness)"
pass "the loop lights the keys in the dark"

for attempt in $(seq 1 40); do
  [[ -s $pid_file ]] && break
  sleep 0.1
done
[[ $(<"$pid_file") == "$loop_pid" ]] || fail "the loop publishes its pid" "got $(cat "$pid_file" 2>/dev/null)"
pass "the loop publishes its pid for --idle and --active"

poke() {
  kill -USR1 "$loop_pid"
}

run_auto --idle
wait_for_brightness 0 || fail "idle turns the keys off" "got $(brightness)"
pass "idle turns the keys off"

run_auto --active
wait_for_brightness 255 || fail "the first input brings the keys back" "got $(brightness)"
pass "the first input brings the keys back"

printf '400\n' >"$als"
poke
wait_for_brightness 0 || fail "a bright room turns the keys off" "got $(brightness)"
pass "a bright room turns the keys off"

printf '175\n' >"$als"
poke
sleep 0.5
[[ $(brightness) == 0 ]] || fail "keys stay off just below the bright threshold" "got $(brightness)"
pass "hysteresis keeps the keys off just below the bright threshold"

printf '100\n' >"$als"
poke
wait_for_brightness 117 || fail "keys relight once the room is dark enough for a visible level" "got $(brightness)"
pass "keys relight once the room is dark enough for a visible level"

run_auto --idle
wait_for_brightness 0 || fail "idle turns the keys off at a mid level" "got $(brightness)"
printf '200\n' >"$led"
run_auto --active
sleep 0.5
[[ $(brightness) == 200 ]] || fail "a level set by hand while idle survives the return from idle" "got $(brightness)"
pass "a level set by hand while idle survives the return from idle"

run_auto --idle
wait_for_brightness 0 || fail "idle turns the hand-set keys off" "got $(brightness)"
run_auto --active
wait_for_brightness 200 || fail "the return from idle restores the hand-set level" "got $(brightness)"
pass "the return from idle restores the hand-set level"

kill "$loop_pid"
wait "$loop_pid" 2>/dev/null || true
loop_pid=""
[[ ! -e $pid_file ]] || fail "the loop removes its pid file on exit"
pass "the loop removes its pid file on exit"

run_auto --idle || fail "--idle without a running loop should still succeed"
run_auto --active || fail "--active without a running loop should still succeed"
pass "idle reporting without the loop is harmless"

service="$ROOT/shell/plugins/services/keyboard-backlight/Service.qml"
service_manifest="$ROOT/shell/plugins/services/keyboard-backlight/manifest.json"
grep -F '"id": "omarchy.keyboard-backlight"' "$service_manifest" >/dev/null
grep -F '"service": "Service.qml"' "$service_manifest" >/dev/null
grep -F 'IdleMonitor' "$service" >/dev/null
grep -F 'respectInhibitors: false' "$service" >/dev/null
grep -F '"--idle"' "$service" >/dev/null
grep -F '"--active"' "$service" >/dev/null
grep -F '"--idle-seconds"' "$service" >/dev/null
grep -F '"--available"' "$service" >/dev/null
grep -F 'omarchy.keyboard-backlight' "$ROOT/shell/plugins/README.md" >/dev/null
pass "the keyboard backlight service relays idle to the command"

manual="$ROOT/manual/34-keyboard-mouse-trackpad.md"
grep -F 'Lock and lid-close keep the keys off' "$manual" >/dev/null &&
  fail "manual still claims lock and lid-close turn the keys off"
grep -F 'Automatic control pauses while the screen is locked or the lid is closed' "$manual" >/dev/null ||
  fail "manual does not describe lock and lid-close as a pause"
grep -F 'come back at the first input' "$manual" >/dev/null ||
  fail "manual does not describe idle-off and wake"
grep -F 'keyboard-backlight.conf' "$manual" >/dev/null ||
  fail "manual does not name the config file"
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
