#!/bin/bash

# Hardware check for the display on an Apple Silicon Mac: notch, software
# cursor, greeter, panel backlight, external DDC and the ambient-light keyboard
# loop. Not part of ./test/shell: it needs the real Mac and a desktop session.
# Run it as the desktop user, from a terminal in the session or over SSH:
#
#   bash test/manual/apple-display-check.sh [--read-only]
#
# It steps the panel brightness down and restores it, tries an external
# monitor's brightness and blanks the keyboard for the ambient-light loop to
# relight; --read-only skips those three. logind lets only a session on a seat
# change a backlight, so from a shell without one (SSH) the check reruns itself
# in the user's service manager, which carries the desktop session's
# environment.

set -uo pipefail
read_only=0
[[ ${1:-} == "--read-only" ]] && read_only=1
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID}
if [[ -z ${OMARCHY_DISPLAY_CHECK_IN_SESSION:-} && -n ${XDG_SESSION_ID:-} &&
  -z $(loginctl show-session "$XDG_SESSION_ID" -p Seat --value 2>/dev/null) ]]; then
  exec systemd-run --user --wait --pipe --quiet --collect --setenv=OMARCHY_DISPLAY_CHECK_IN_SESSION=1 \
    -- bash "$(realpath "$0")" "$@"
fi
if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -n1)
  export HYPRLAND_INSTANCE_SIGNATURE
fi
failures=0
check() {
  local description=$1
  shift
  if "$@"; then
    printf 'ok - %s\n' "$description"
  else
    printf 'FAIL - %s\n' "$description"
    failures=$((failures + 1))
  fi
}

check 'detector says apple-silicon' test "$(omarchy-hw-platform)" = apple-silicon
check 'omarchy-mac is installed' pacman -Q omarchy-mac

# Notch
check 'appledrm show_notch=1 is configured' bash -c "modprobe --showconfig | grep -qx 'options appledrm show_notch=1'"
check 'appledrm is showing the notch strip' grep -qx Y /sys/module/appledrm/parameters/show_notch
hyprctl monitors -j | jq -r '.[] | "  monitor \(.name) \(.width)x\(.height) scale \(.scale)"'
echo '  expect eDP-1 3456x2234 on the 16" M2 Max (2160 without the strip); check by eye that the bar clears the camera cutout'

# Cursor
check 'Hyprland draws the cursor in software' bash -c "hyprctl getoption cursor:no_hardware_cursors | grep -qx 'int: 1'"
check 'the software cursor was written once' bash -c "(( \$(grep -c no_hardware_cursors ~/.config/hypr/looknfeel.lua) == 1 ))"

# Greeter
check 'sddm waits for the display controller' bash -c 'systemctl cat sddm.service | grep -qx "ExecStartPre=-/usr/lib/omarchy-mac/wait-for-display"'
check 'the display controller card exists' test -e /dev/dri/by-path/platform-soc:display-subsystem-card
journalctl -b -k -o short-monotonic --no-pager | grep -m1 -i 'apple-drm\|appledrm' | sed 's/^/  kernel: /'
journalctl -b -u sddm -o short-monotonic --no-pager | grep -m2 -E 'Starting|Started' | sed 's/^/  sddm: /'
echo '  expect sddm Started after the appledrm card; by eye: greeter typing fills dots on the built-in panel with USB-C monitors attached'

# Panel backlight
check 'the panel backlight is apple-panel-bl' test "$(omarchy-hw-display)" = apple-panel-bl
external=$(hyprctl monitors -j | jq -r '[.[] | select(.name | test("^(eDP|LVDS|DSI)-") | not)][0].name // empty')
if (( read_only )); then
  echo '  read-only: skipped the panel and external brightness steps'
else
  before=$(brightnessctl -d apple-panel-bl get)
  omarchy-brightness-display --no-osd --monitor eDP-1 5%-
  after=$(brightnessctl -d apple-panel-bl get)
  brightnessctl -d apple-panel-bl set "$before" >/dev/null
  check 'brightness keys change the built-in panel' test "$before" != "$after"
fi
if (( ! read_only )) && [[ -n $external ]]; then
  before=$(brightnessctl -d apple-panel-bl get)
  start=$(date +%s%N)
  omarchy-brightness-display --no-osd --monitor "$external" 5%- && status=0 || status=$?
  elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
  echo "  external $external: exit $status in ${elapsed} ms"
  check "external $external without DDC fails fast" test "$status" != 0 -a "$elapsed" -lt 1000
  check 'external brightness leaves the built-in panel alone' test "$(brightnessctl -d apple-panel-bl get)" = "$before"
elif [[ -z $external ]]; then
  echo '  no external monitor attached; skipped the DDC case'
fi

# Ambient light keyboard
check 'ALS and keyboard LED are available' omarchy-brightness-keyboard-auto --available
check 'the ALS keyboard loop runs' systemctl --user is-active --quiet omarchy-brightness-keyboard-auto.service
echo "  lux $(cat /sys/bus/iio/devices/iio:device*/in_illuminance_input 2>/dev/null | head -n1), keys $(brightnessctl -d kbd_backlight get)/255"
if (( read_only )); then
  echo '  read-only: skipped the lock-style keyboard blank'
else
  omarchy-brightness-keyboard off
  sleep 12
  lit=$(brightnessctl -d kbd_backlight get)
  lux=$(omarchy-brightness-keyboard-auto --map-lux "$(cat /sys/bus/iio/devices/iio:device*/in_illuminance_input | head -n1 | cut -d. -f1)")
  echo "  after a lock-style blank: keys $lit/255, room maps to $lux%"
  check 'keys blanked by the lock screen light up again in a room that wants them' bash -c "(( $lux == 0 || $lit > 0 ))"
fi
echo '  by eye: dim the keys to off with the keyboard-brightness keys; they stay off until the room light changes a lot'

printf '\n%d failure(s)\n' "$failures"
(( failures == 0 ))
