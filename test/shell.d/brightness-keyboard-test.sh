#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

keyboard="$ROOT/bin/omarchy-brightness-keyboard"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export XDG_RUNTIME_DIR="$test_tmp/run"
export OMARCHY_LEDS_DIR="$test_tmp/leds"
# Not the real LED's name, so a lookup that ignores OMARCHY_LEDS_DIR fails here.
led_dir="$OMARCHY_LEDS_DIR/test::kbd_backlight"
stub="$test_tmp/bin"
mkdir -p "$XDG_RUNTIME_DIR" "$led_dir" "$stub"
printf '255\n' >"$led_dir/max_brightness"

# brightnessctl over the fake LED; -s saves the level and -r restores it. Like
# brightnessctl 0.5, a restore keeps the save.
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
chmod +x "$stub/brightnessctl"
export PATH="$stub:$PATH"

set_led() {
  printf '%s\n' "$1" >"$led_dir/brightness"
}

led() {
  cat "$led_dir/brightness"
}

# An old blank left 0 saved, e.g. from a daytime lock with the keys off.
printf '0\n' >"$led_dir/saved"
set_led 128
"$keyboard" restore
[[ $(led) == 128 ]] || fail "a restore with nothing blanked brings back an old save" "got $(led)"
pass "a quick unlock or screensaver wake leaves the keys alone"

"$keyboard" off
[[ $(led) == 0 ]] || fail "the lock screen blank turns the keys off" "got $(led)"
"$keyboard" restore
[[ $(led) == 128 ]] || fail "waking after a blank brings back the lit level" "got $(led)"
pass "waking after a blank brings back the level from before it"

# A blank the wake never undid, then keys turned off by hand and blanked again:
# the wake brings back the latest level, not the one from before the first blank.
"$keyboard" off
set_led 0
"$keyboard" off
"$keyboard" restore
[[ $(led) == 0 ]] || fail "a wake relit keys turned off by hand with a level from an older blank" "got $(led)"
pass "a wake brings back the level from before the latest blank"

set_led 50
"$keyboard" restore
[[ $(led) == 50 ]] || fail "a repeat restore brings back the last blank's level again" "got $(led)"
pass "a wake undoes a blank once"
