#!/bin/bash
# Checks Touch Bar detection and the handoff helper's device discovery
# against fake sysfs trees. Needs no root: only the "devices" verb runs, and
# it never touches the real system.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HW="$ROOT/bin/omarchy-hw-touchbar"
HANDOFF="$ROOT/bin/omarchy-touchbar-handoff"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0
failures=0

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "✓ $label"
    ((++pass))
  else
    echo "✗ $label"
    ((++failures))
  fi
}

not() {
  ! "$@"
}

# A fake /sys/class/input with the given device names.
fake_inputs() {
  local dir="$1" i=0 name
  shift
  rm -rf "$dir"
  for name in "$@"; do
    mkdir -p "$dir/input$i"
    printf '%s\n' "$name" >"$dir/input$i/name"
    ((++i))
  done
}

# A fake /sys with a Touch Bar DRM card, digitizer, and panel backlight, plus
# the main display's card and backlight so discovery has to pick correctly.
fake_sysfs() {
  local sys="$1" drm_driver="$2" touch_name="$3" backlight="$4"
  rm -rf "$sys"
  mkdir -p "$sys/drivers/$drm_driver" "$sys/drivers/apple-drm" "$sys/drivers/panel-summit" "$sys/drivers/apple-panel"
  mkdir -p "$sys/class/drm/card0/device" "$sys/class/drm/card2/device"
  ln -s "$sys/drivers/apple-drm" "$sys/class/drm/card0/device/driver"
  ln -s "$sys/drivers/$drm_driver" "$sys/class/drm/card2/device/driver"
  mkdir -p "$sys/class/input/event1/device" "$sys/class/input/event3/device"
  printf 'Apple MTP keyboard\n' >"$sys/class/input/event1/device/name"
  printf '%s\n' "$touch_name" >"$sys/class/input/event3/device/name"
  mkdir -p "$sys/class/backlight/apple-panel-bl/device" "$sys/class/backlight/$backlight/device"
  ln -s "$sys/drivers/apple-panel" "$sys/class/backlight/apple-panel-bl/device/driver"
  ln -s "$sys/drivers/panel-summit" "$sys/class/backlight/$backlight/device/driver"
}

detects_touch_bar() {
  fake_inputs "$WORK/input" "$@"
  OMARCHY_INPUT_DEVICES_PATH="$WORK/input" "$HW"
}

handoff_devices() {
  fake_sysfs "$WORK/sys" "$@"
  OMARCHY_SYSFS_PATH="$WORK/sys" "$HANDOFF" devices
}

check "detects the M2 Touch Bar" detects_touch_bar "Apple MTP keyboard" "Mac14,7 Touch Bar"
check "detects the M1 Touch Bar" detects_touch_bar "MacBookPro17,1 Touch Bar"
check "detects the T2 Touch Bar" detects_touch_bar "Apple Inc. Touch Bar Display Touchpad"
check "ignores a Mac without one" not detects_touch_bar "Apple MTP keyboard" "Apple MTP multi-touch"
check "ignores an empty sysfs" not detects_touch_bar

expected=$'drm=/dev/dri/card2\ntouch=/dev/input/event3\nbacklight='"$WORK"$'/sys/class/backlight/228600000.dsi.0/brightness'
check "finds the Apple Silicon Touch Bar devices" \
  [ "$(handoff_devices adp "Mac14,7 Touch Bar" 228600000.dsi.0)" == "$expected" ]

expected=$'drm=/dev/dri/card2\ntouch=/dev/input/event3\nbacklight='"$WORK"$'/sys/class/backlight/appletb_backlight/brightness'
check "finds the T2 Touch Bar devices" \
  [ "$(handoff_devices appletbdrm "Apple Inc. Touch Bar Display Touchpad" appletb_backlight)" == "$expected" ]

check "refuses unknown verbs" not "$HANDOFF" bogus

echo
echo "$pass passed, $failures failed"
(( failures == 0 ))
