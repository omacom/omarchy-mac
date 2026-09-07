#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/v4l2-ctl" <<'SH'
#!/bin/bash

[[ ${OMARCHY_TEST_NO_WEBCAM:-false} == "true" ]] && exit 0

case "$1" in
--list-devices)
  printf '%s\n' "ipu6 (PCI:0000:00:05.0):"
  printf '\t%s\n' "/dev/video0"
  printf '\t%s\n' "/dev/video1"

  if [[ ${OMARCHY_TEST_RAW_WEBCAM:-false} != "true" ]]; then
    printf '\n%s\n' "Built-in Webcam: Integrated Camera"
    printf '\t%s\n' "/dev/video42"
    printf '\t%s\n' "/dev/video43"
    printf '\n%s\n' "USB Capture Card: External Camera"
    printf '\t%s\n' "/dev/video2"
  fi

  if [[ ${OMARCHY_TEST_DUAL_NODE_WEBCAM:-false} == "true" ]]; then
    printf '\n%s\n' "Dual Node Camera: ISP Wrapper"
    printf '\t%s\n' "/dev/video7"
    printf '\t%s\n' "/dev/video8"
    printf '\n%s\n' "Metadata Only: Sensor"
    printf '\t%s\n' "/dev/video9"
  fi
  ;;
--device)
  case "$2" in
  /dev/video0) device_capability="Video Output" ;;
  /dev/video1) device_capability="Metadata Capture" ;;
  /dev/video7 | /dev/video9) device_capability="Video Output" ;;
  *) device_capability="Video Capture" ;;
  esac

  printf '%s\n' \
    "Driver Info:" \
    $'\tCapabilities     : 0x84a00001' \
    $'\t\tVideo Capture' \
    $'\tDevice Caps      : 0x04200001' \
    $'\t\t'"$device_capability"
  ;;
esac
SH

cat >"$stub_bin/omarchy-menu-select" <<'SH'
#!/bin/bash

printf '%s\n' "$@" >"$OMARCHY_TEST_MENU_ARGS"
printf '%s\n' "$3"
SH

cat >"$stub_bin/omarchy-capture-screenrecording" <<'SH'
#!/bin/bash

printf '%s\n' "$@" >"$OMARCHY_TEST_RECORDER_ARGS"
SH

cat >"$stub_bin/omarchy-notification-send" <<'SH'
#!/bin/bash

printf '%s\n' "$@" >"$OMARCHY_TEST_NOTIFICATION_ARGS"
SH

chmod +x "$stub_bin"/*

export PATH="$stub_bin:$ROOT/bin:$PATH"
# The resize helper anchors to a region file here, so keep it out of the real one
export XDG_RUNTIME_DIR="$tmp_dir"
export OMARCHY_TEST_MENU_ARGS="$tmp_dir/menu-args"
export OMARCHY_TEST_RECORDER_ARGS="$tmp_dir/recorder-args"
export OMARCHY_TEST_NOTIFICATION_ARGS="$tmp_dir/notification-args"

omarecord_root="$tmp_dir/omarecord-root"
mkdir -p "$omarecord_root/bin"
export OMARCHY_TEST_OMARECORD_ARGS="$tmp_dir/omarecord-args"

cat >"$omarecord_root/bin/omarchy-capture-screenrecording" <<'SH'
#!/bin/bash

printf '%s\0' "$@" >"$OMARCHY_TEST_OMARECORD_ARGS"
exit "${OMARCHY_TEST_OMARECORD_STATUS:-0}"
SH
chmod +x "$omarecord_root/bin/omarchy-capture-screenrecording"

OMARCHY_PATH="$omarecord_root" "$ROOT/bin/omarecord" --fullscreen --show-keystrokes "two words" ""
printf '%s\0' --fullscreen --show-keystrokes "two words" "" >"$tmp_dir/expected-omarecord-args"
cmp -s "$OMARCHY_TEST_OMARECORD_ARGS" "$tmp_dir/expected-omarecord-args" ||
  fail "omarecord forwards every argument unchanged"
pass "omarecord forwards every argument unchanged"

if OMARCHY_PATH="$omarecord_root" OMARCHY_TEST_OMARECORD_STATUS=37 "$ROOT/bin/omarecord" --stop-recording; then
  fail "omarecord returns the implementation status"
else
  omarecord_status=$?
fi
(( omarecord_status == 37 )) || fail "omarecord returns the implementation status" "expected: 37\nactual:   $omarecord_status"
printf '%s\0' --stop-recording >"$tmp_dir/expected-omarecord-stop-args"
cmp -s "$OMARCHY_TEST_OMARECORD_ARGS" "$tmp_dir/expected-omarecord-stop-args" ||
  fail "omarecord forwards the stop action unchanged"
pass "omarecord forwards the stop action and returns the implementation status"

mapfile -t capture_devices < <(omarchy-capture-webcam-list)
expected_capture_devices=(
  "/dev/video42  Built-in Webcam: Integrated Camera"
  "/dev/video2  USB Capture Card: External Camera"
)

if [[ ${capture_devices[*]} != "${expected_capture_devices[*]}" ]]; then
  fail "webcam detection filters output-only devices and collapses each capture group" \
    "expected: ${expected_capture_devices[*]}\nactual:   ${capture_devices[*]}"
fi
pass "webcam detection filters output-only devices and collapses each capture group"

dual_node=$(OMARCHY_TEST_DUAL_NODE_WEBCAM=true omarchy-capture-webcam-list) ||
  fail "webcam listing exits zero when the trailing device is filtered"
pass "webcam listing exits zero when the trailing device is filtered"

expected_dual_node="/dev/video42  Built-in Webcam: Integrated Camera
/dev/video2  USB Capture Card: External Camera
/dev/video8  Dual Node Camera: ISP Wrapper"
[[ $dual_node == "$expected_dual_node" ]] ||
  fail "webcam detection falls through to a later capture-capable node in a group" "$dual_node"
pass "webcam detection falls through to a later capture-capable node in a group"

if "$ROOT/bin/omarchy-hw-webcam"; then
  pass "webcam hardware detection succeeds when a capture device is available"
else
  fail "webcam hardware detection succeeds when a capture device is available"
fi

if OMARCHY_TEST_RAW_WEBCAM=true "$ROOT/bin/omarchy-hw-webcam"; then
  fail "webcam hardware detection rejects output-only video devices"
else
  pass "webcam hardware detection rejects output-only video devices"
fi

if OMARCHY_TEST_NO_WEBCAM=true "$ROOT/bin/omarchy-hw-webcam"; then
  fail "webcam hardware detection fails when no video device is available"
else
  pass "webcam hardware detection fails when no video device is available"
fi

if OMARCHY_TEST_RAW_WEBCAM=true "$ROOT/bin/omarchy-capture-screenrecording-with-webcam"; then
  fail "screenrecording webcam picker rejects output-only video devices"
fi
grep -Fx 'No webcam devices found' "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null || \
  fail "screenrecording webcam picker reports no capture-capable device"
pass "screenrecording webcam picker rejects output-only video devices"

"$ROOT/bin/omarchy-capture-screenrecording-with-webcam"

expected_menu_args="$tmp_dir/expected-menu-args"
printf '%s\n' \
  "Select Webcam" \
  "/dev/video42  Built-in Webcam: Integrated Camera" \
  "/dev/video2  USB Capture Card: External Camera" \
  "--" \
  "--width" \
  "520" \
  "--maxheight" \
  "520" >"$expected_menu_args"

if ! cmp -s "$OMARCHY_TEST_MENU_ARGS" "$expected_menu_args"; then
  fail "screenrecording webcam picker passes each webcam as a menu option" "$(diff -u "$expected_menu_args" "$OMARCHY_TEST_MENU_ARGS")"
fi
pass "screenrecording webcam picker passes each webcam as a menu option"

expected_recorder_args="$tmp_dir/expected-recorder-args"
printf '%s\n' \
  "--with-desktop-audio" \
  "--with-microphone-audio" \
  "--with-webcam" \
  "--webcam-device=/dev/video2" >"$expected_recorder_args"

if ! cmp -s "$OMARCHY_TEST_RECORDER_ARGS" "$expected_recorder_args"; then
  fail "screenrecording webcam picker starts recording with selected device" "$(diff -u "$expected_recorder_args" "$OMARCHY_TEST_RECORDER_ARGS")"
fi
pass "screenrecording webcam picker starts recording with selected device"

first_webcam=$(omarchy-capture-webcam-list | sed -n '1s/[[:space:]].*//p')
[[ $first_webcam == "/dev/video42" ]] || fail "screenrecording auto-detection selects the first capture device"
grep -F 'WEBCAM_DEVICE=$(omarchy-capture-webcam-list' "$ROOT/bin/omarchy-capture-screenrecording" >/dev/null || \
  fail "screenrecording auto-detection uses capture-capable webcams"
pass "screenrecording auto-detection uses the first capture-capable webcam"

cat >"$stub_bin/hyprctl" <<'SH'
#!/bin/bash

case $1 in
clients)
  printf '[{"address":"0xabc","title":"%s","size":[%s,%s],"monitor":2}]\n' \
    "${OMARCHY_TEST_CLIENT_TITLE:-WebcamOverlay}" \
    "${OMARCHY_TEST_CLIENT_WIDTH:-178}" \
    "${OMARCHY_TEST_CLIENT_HEIGHT:-200}"
  ;;
monitors)
  printf '[{"id":2,"x":1280,"y":-100,"width":%s,"height":%s,"scale":%s}]\n' \
    "${OMARCHY_TEST_MONITOR_WIDTH:-2560}" \
    "${OMARCHY_TEST_MONITOR_HEIGHT:-1600}" \
    "${OMARCHY_TEST_MONITOR_SCALE:-2}"
  ;;
dispatch)
  printf '%s\n' "$*" >>"$OMARCHY_TEST_HYPRCTL_ARGS"
  ;;
esac
SH
chmod +x "$stub_bin/hyprctl"

export OMARCHY_TEST_HYPRCTL_ARGS="$tmp_dir/hyprctl-args"

"$ROOT/bin/omarchy-capture-webcam-resize" smaller

expected_hyprctl_args="$tmp_dir/expected-hyprctl-args"
printf '%s\n' \
  'dispatch hl.dsp.window.resize({ window = "address:0xabc", x = 128, y = 144 })' \
  'dispatch hl.dsp.window.move({ window = "address:0xabc", x = 2392, y = 516 })' >"$expected_hyprctl_args"

if ! cmp -s "$OMARCHY_TEST_HYPRCTL_ARGS" "$expected_hyprctl_args"; then
  fail "webcam resize preserves its aspect ratio and corner anchor" "$(diff -u "$expected_hyprctl_args" "$OMARCHY_TEST_HYPRCTL_ARGS")"
fi
pass "webcam resize preserves its aspect ratio and corner anchor"

: >"$OMARCHY_TEST_HYPRCTL_ARGS"
OMARCHY_TEST_MONITOR_WIDTH=1920 \
  OMARCHY_TEST_MONITOR_HEIGHT=1080 \
  OMARCHY_TEST_MONITOR_SCALE=1 \
  OMARCHY_TEST_CLIENT_WIDTH=128 \
  OMARCHY_TEST_CLIENT_HEIGHT=144 \
  "$ROOT/bin/omarchy-capture-webcam-resize" reset

printf '%s\n' \
  'dispatch hl.dsp.window.resize({ window = "address:0xabc", x = 240, y = 270 })' \
  'dispatch hl.dsp.window.move({ window = "address:0xabc", x = 2920, y = 670 })' >"$expected_hyprctl_args"

if ! cmp -s "$OMARCHY_TEST_HYPRCTL_ARGS" "$expected_hyprctl_args"; then
  fail "webcam default size adapts to monitor resolution" "$(diff -u "$expected_hyprctl_args" "$OMARCHY_TEST_HYPRCTL_ARGS")"
fi
pass "webcam default size adapts to monitor resolution"

: >"$OMARCHY_TEST_HYPRCTL_ARGS"
OMARCHY_TEST_CLIENT_TITLE="Other Window" "$ROOT/bin/omarchy-capture-webcam-resize" larger

if [[ -s $OMARCHY_TEST_HYPRCTL_ARGS ]]; then
  fail "webcam resize ignores other windows" "$(cat "$OMARCHY_TEST_HYPRCTL_ARGS")"
fi
pass "webcam resize ignores other windows"

region_file="$XDG_RUNTIME_DIR/omarchy-screenrecord-region"

: >"$OMARCHY_TEST_HYPRCTL_ARGS"
echo "800x600+100+100" >"$region_file"
"$ROOT/bin/omarchy-capture-webcam-resize" reset

printf '%s\n' \
  'dispatch hl.dsp.window.resize({ window = "address:0xabc", x = 133, y = 150 })' \
  'dispatch hl.dsp.window.move({ window = "address:0xabc", x = 727, y = 510 })' >"$expected_hyprctl_args"

if ! cmp -s "$OMARCHY_TEST_HYPRCTL_ARGS" "$expected_hyprctl_args"; then
  fail "webcam anchors to the recorded region" "$(diff -u "$expected_hyprctl_args" "$OMARCHY_TEST_HYPRCTL_ARGS")"
fi
pass "webcam anchors to the recorded region"

printf '%s\n' \
  'dispatch hl.dsp.window.resize({ window = "address:0xabc", x = 178, y = 200 })' \
  'dispatch hl.dsp.window.move({ window = "address:0xabc", x = 2342, y = 460 })' >"$expected_hyprctl_args"

for region in "not-a-region" ""; do
  : >"$OMARCHY_TEST_HYPRCTL_ARGS"
  printf '%s' "$region" >"$region_file"
  "$ROOT/bin/omarchy-capture-webcam-resize" reset

  if ! cmp -s "$OMARCHY_TEST_HYPRCTL_ARGS" "$expected_hyprctl_args"; then
    fail "webcam falls back to the monitor for an unusable region" "$(diff -u "$expected_hyprctl_args" "$OMARCHY_TEST_HYPRCTL_ARGS")"
  fi
done
pass "webcam falls back to the monitor for an unusable region"

# A region too narrow for presets scaled from its height shrinks the whole
# ladder, so the three sizes stay distinct and each one fits inside the margins
: >"$OMARCHY_TEST_HYPRCTL_ARGS"
echo "200x1200+0+0" >"$region_file"
for size in small medium large; do
  "$ROOT/bin/omarchy-capture-webcam-resize" "$size"
done

printf '%s\n' \
  'dispatch hl.dsp.window.resize({ window = "address:0xabc", x = 64, y = 72 })' \
  'dispatch hl.dsp.window.move({ window = "address:0xabc", x = 96, y = 1088 })' \
  'dispatch hl.dsp.window.resize({ window = "address:0xabc", x = 89, y = 100 })' \
  'dispatch hl.dsp.window.move({ window = "address:0xabc", x = 71, y = 1060 })' \
  'dispatch hl.dsp.window.resize({ window = "address:0xabc", x = 120, y = 135 })' \
  'dispatch hl.dsp.window.move({ window = "address:0xabc", x = 40, y = 1025 })' >"$expected_hyprctl_args"

if ! cmp -s "$OMARCHY_TEST_HYPRCTL_ARGS" "$expected_hyprctl_args"; then
  fail "webcam sizes stay distinct and inside a narrow region" "$(diff -u "$expected_hyprctl_args" "$OMARCHY_TEST_HYPRCTL_ARGS")"
fi
pass "webcam sizes stay distinct and inside a narrow region"

rm -f "$region_file"

grep -F 'o.bind("SUPER + ALT + code:34", "Make webcam overlay smaller", "omarchy-capture-webcam-resize smaller")' \
  "$ROOT/default/hypr/bindings/utilities.lua" >/dev/null || fail "webcam smaller hotkey is configured"
grep -F 'o.bind("SUPER + ALT + code:35", "Make webcam overlay larger", "omarchy-capture-webcam-resize larger")' \
  "$ROOT/default/hypr/bindings/utilities.lua" >/dev/null || fail "webcam larger hotkey is configured"
pass "webcam resize hotkeys are configured"

grep -F 'o.bind("ALT + PRINT", "OmaRecord", "omarchy-capture-screenrecording --stop-recording || omarchy-menu toggle trigger.capture.screenrecord")' \
  "$ROOT/default/hypr/bindings/utilities.lua" >/dev/null || fail "Print Screen recorder binding is branded OmaRecord"
grep -F 'o.bind("SUPER + ALT + F12", "OmaRecord Display", "omarchy-capture-screenrecording --fullscreen")' \
  "$ROOT/default/hypr/bindings/media.lua" >/dev/null || fail "Apple fullscreen recorder binding is branded OmaRecord"
grep -F 'o.bind("SUPER + ALT + XF86AudioRaiseVolume", "OmaRecord Display (Apple top row)", "omarchy-capture-screenrecording --fullscreen")' \
  "$ROOT/default/hypr/bindings/media.lua" >/dev/null || fail "Apple top-row recorder binding is branded OmaRecord"
pass "recorder binding descriptions use OmaRecord"

grep -F -- '--wayland-app-id="WebcamOverlay-$WEBCAM_SIZE"' \
  "$ROOT/bin/omarchy-capture-screenrecording" >/dev/null || fail "webcam uses a dedicated size-specific app id"

webcam_rules="$ROOT/default/hypr/apps/webcam-overlay.lua"
grep -F 'move = { "(monitor_w-monitor_h*4/25-40)", "(monitor_h-monitor_h*9/50-40)" }' "$webcam_rules" >/dev/null || \
  fail "small webcam starts at its final corner position"
grep -F 'move = { "(monitor_w-monitor_h*2/9-40)", "(monitor_h-monitor_h/4-40)" }' "$webcam_rules" >/dev/null || \
  fail "medium webcam starts at its final corner position"
grep -F 'move = { "(monitor_w-monitor_h*3/10-40)", "(monitor_h-monitor_h*27/80-40)" }' "$webcam_rules" >/dev/null || \
  fail "large webcam starts at its final corner position"
pass "webcam size rules place the initial window in its final corner"

recording_stub_bin="$tmp_dir/recording-bin"
mkdir -p "$recording_stub_bin"

export OMARCHY_TEST_OVERLAY_ARGS="$tmp_dir/overlay-args"
export OMARCHY_TEST_OVERLAY_LAST_PID="$tmp_dir/overlay-last-pid"
export OMARCHY_TEST_OVERLAY_STOPPED="$tmp_dir/overlay-stopped"
export OMARCHY_TEST_RECORDER_PROCESS_PID="$tmp_dir/recorder-process-pid"
export OMARCHY_TEST_RECORDER_PROCESS_ARGS="$tmp_dir/recorder-process-args"
export OMARCHY_SCREENRECORD_DIR="$tmp_dir/recordings"
mkdir -p "$OMARCHY_SCREENRECORD_DIR"

cat >"$recording_stub_bin/omarchy-cmd-missing" <<'SH'
#!/bin/bash

[[ $1 == "showmethekey-gtk" && ${OMARCHY_TEST_SHOWMETHEKEY_MISSING:-false} == "true" ]]
SH

cat >"$recording_stub_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash

case "$1" in
gpu-screen-recorder) [[ ${OMARCHY_TEST_BACKEND:-gpu-screen-recorder} == "gpu-screen-recorder" ]] ;;
wf-recorder) exit 0 ;;
*) exit 1 ;;
esac
SH

cat >"$recording_stub_bin/grep" <<'SH'
#!/bin/bash

if [[ $* == *"/proc/device-tree/compatible"* ]]; then
  [[ ${OMARCHY_TEST_BACKEND:-gpu-screen-recorder} == "wf-recorder" ]]
else
  exec /usr/bin/grep "$@"
fi
SH

cat >"$recording_stub_bin/showmethekey-gtk" <<'SH'
#!/bin/bash

printf '%s\n' "$@" >"$OMARCHY_TEST_OVERLAY_ARGS"
[[ ${OMARCHY_TEST_SHOWMETHEKEY_FAIL:-false} == "true" ]] && exit 1
printf '%s\n' "$$" >"$OMARCHY_TEST_OVERLAY_LAST_PID"
trap 'printf "%s\n" "$$" >>"$OMARCHY_TEST_OVERLAY_STOPPED"; exit 0' TERM INT
while :; do
  sleep 1
done
SH

cat >"$recording_stub_bin/hyprctl" <<'SH'
#!/bin/bash

case "$1 $2" in
"monitors -j")
  printf '%s\n' '[{"focused":true,"width":1920,"height":1080}]'
  ;;
"clients -j")
  if [[ ${OMARCHY_TEST_HYPR_MAP:-true} == "true" && -s $OMARCHY_TEST_OVERLAY_LAST_PID ]]; then
    pid=$(cat "$OMARCHY_TEST_OVERLAY_LAST_PID")
    printf '[{"pid":%s,"class":"showmethekey-gtk","title":"Floating Window - Show Me The Key"}]\n' "$pid"
  else
    printf '%s\n' '[]'
  fi
  ;;
esac
SH

cat >"$recording_stub_bin/ps" <<'SH'
#!/bin/bash

pid=$2
if kill -0 "$pid" 2>/dev/null; then
  printf '%s\n' 'showmethekey-gtk -k -A -C'
else
  exit 1
fi
SH

cat >"$recording_stub_bin/recorder-stub" <<'SH'
#!/bin/bash

printf '%s\n' "$(basename "$0")" "$@" >"$OMARCHY_TEST_RECORDER_PROCESS_ARGS"
printf '%s\n' "$$" >"$OMARCHY_TEST_RECORDER_PROCESS_PID"
[[ ${OMARCHY_TEST_RECORDER_FAIL:-false} == "true" ]] && exit 1

filename=""
while (($#)); do
  case "$1" in
  -o | -f)
    filename=$2
    shift 2
    ;;
  *)
    shift
    ;;
  esac
done

[[ -n $filename && ${OMARCHY_TEST_RECORDER_NO_FILE:-false} != "true" ]] && : >"$filename"
trap 'exit 0' TERM INT
while :; do
  sleep 1
done
SH
ln -s recorder-stub "$recording_stub_bin/gpu-screen-recorder"
ln -s recorder-stub "$recording_stub_bin/wf-recorder"

cat >"$recording_stub_bin/pgrep" <<'SH'
#!/bin/bash

[[ -s $OMARCHY_TEST_RECORDER_PROCESS_PID ]] || exit 1
pid=$(cat "$OMARCHY_TEST_RECORDER_PROCESS_PID")
kill -0 "$pid" 2>/dev/null || exit 1
printf '%s\n' "$pid"
SH

cat >"$recording_stub_bin/pkill" <<'SH'
#!/bin/bash

[[ -s $OMARCHY_TEST_RECORDER_PROCESS_PID ]] || exit 1
pid=$(cat "$OMARCHY_TEST_RECORDER_PROCESS_PID")
kill -TERM "$pid" 2>/dev/null
SH

cat >"$recording_stub_bin/omarchy-hyprland-monitor-focused" <<'SH'
#!/bin/bash

printf '%s\n' 'eDP-1'
SH

cat >"$recording_stub_bin/omarchy-shell" <<'SH'
#!/bin/bash
SH

cat >"$recording_stub_bin/ffprobe" <<'SH'
#!/bin/bash
SH

cat >"$recording_stub_bin/ffmpeg" <<'SH'
#!/bin/bash

exit 1
SH

chmod +x "$recording_stub_bin"/*
export PATH="$recording_stub_bin:$PATH"

keystroke_state="$XDG_RUNTIME_DIR/omarchy-screenrecord-showmethekey.pid"

stop_test_recording() {
  OMARCHY_TEST_BACKEND=$1 "$ROOT/bin/omarchy-capture-screenrecording" --stop-recording
}

wait_for_process_exit() {
  local pid=$1 count=0
  while kill -0 "$pid" 2>/dev/null && ((count < 40)); do
    sleep 0.05
    ((count++))
  done
  ! kill -0 "$pid" 2>/dev/null
}

test_process_start_time() {
  local stat fields
  IFS= read -r stat <"/proc/$1/stat"
  read -ra fields <<<"${stat#*) }"
  printf '%s\n' "${fields[19]}"
}

wait_for_file() {
  local file=$1 count=0
  while [[ ! -s $file ]] && ((count < 40)); do
    sleep 0.05
    ((count++))
  done
  [[ -s $file ]]
}

wait_for_file_removal() {
  local file=$1 count=0
  while [[ -e $file ]] && ((count < 40)); do
    sleep 0.05
    ((count++))
  done
  [[ ! -e $file ]]
}

grep -F '# omarchy:args=[--fullscreen] [--with-desktop-audio] [--with-microphone-audio] [--with-webcam] [--show-keystrokes]' \
  "$ROOT/bin/omarchy-capture-screenrecording" >/dev/null || fail "screen recording metadata lists --show-keystrokes"
pass "screen recording metadata lists --show-keystrokes"

rm -f "$OMARCHY_TEST_OVERLAY_ARGS" "$keystroke_state" "$OMARCHY_TEST_RECORDER_PROCESS_PID"
OMARCHY_TEST_BACKEND=gpu-screen-recorder \
  OMARCHY_TEST_SHOWMETHEKEY_MISSING=true \
  "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen

[[ ! -e $OMARCHY_TEST_OVERLAY_ARGS ]] || fail "screen recording starts Show Me The Key without --show-keystrokes"
[[ ! -e $keystroke_state ]] || fail "screen recording creates overlay state without --show-keystrokes"
grep -Fx 'gpu-screen-recorder' "$OMARCHY_TEST_RECORDER_PROCESS_ARGS" >/dev/null || \
  fail "default recording still starts gpu-screen-recorder"
stop_test_recording gpu-screen-recorder >/dev/null
pass "screen recording leaves the keystroke overlay off by default"

rm -f "$OMARCHY_TEST_OVERLAY_ARGS" "$OMARCHY_TEST_RECORDER_PROCESS_ARGS" "$OMARCHY_TEST_RECORDER_PROCESS_PID"
if OMARCHY_TEST_BACKEND=gpu-screen-recorder \
  OMARCHY_TEST_SHOWMETHEKEY_MISSING=true \
  "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen --show-keystrokes; then
  fail "screen recording continues when Show Me The Key is missing"
fi
[[ ! -e $OMARCHY_TEST_OVERLAY_ARGS ]] || fail "missing Show Me The Key is still launched"
[[ ! -e $OMARCHY_TEST_RECORDER_PROCESS_ARGS ]] || fail "recorder starts without the requested keystroke overlay"
[[ ! -e $keystroke_state ]] || fail "missing Show Me The Key leaves overlay state"
grep -F 'omarchy pkg add showmethekey' "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null || \
  fail "missing Show Me The Key notification gives the install command"
pass "screen recording aborts when Show Me The Key is unavailable"

rm -f "$OMARCHY_TEST_OVERLAY_ARGS" "$OMARCHY_TEST_RECORDER_PROCESS_ARGS" "$OMARCHY_TEST_RECORDER_PROCESS_PID"
if OMARCHY_TEST_BACKEND=gpu-screen-recorder \
  OMARCHY_SCREENRECORD_USE_PORTAL=true \
  "$ROOT/bin/omarchy-capture-screenrecording" --show-keystrokes; then
  fail "--show-keystrokes continues with portal capture"
fi
[[ ! -e $OMARCHY_TEST_OVERLAY_ARGS ]] || fail "portal rejection launches the keystroke overlay"
[[ ! -e $OMARCHY_TEST_RECORDER_PROCESS_ARGS ]] || fail "portal rejection launches the recorder"
grep -F 'Use monitor or region capture with --show-keystrokes' "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null || \
  fail "portal rejection does not explain the required capture modes"
pass "--show-keystrokes rejects portal capture before startup"

rm -f "$OMARCHY_TEST_RECORDER_PROCESS_ARGS" "$OMARCHY_TEST_RECORDER_PROCESS_PID"
if OMARCHY_TEST_BACKEND=gpu-screen-recorder \
  OMARCHY_TEST_SHOWMETHEKEY_FAIL=true \
  "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen --show-keystrokes; then
  fail "screen recording continues when Show Me The Key fails to launch"
fi
[[ ! -e $OMARCHY_TEST_RECORDER_PROCESS_ARGS ]] || fail "recorder starts after the keystroke overlay fails to launch"
[[ ! -e $keystroke_state ]] || fail "failed keystroke overlay launch leaves state"
grep -F 'Keystroke overlay failed to start' "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null || \
  fail "failed Show Me The Key launch is not reported"
pass "screen recording aborts and cleans state when the keystroke overlay fails to launch"

"$recording_stub_bin/showmethekey-gtk" -k -A -C &
stale_overlay_pid=$!
sleep 0.05
printf '%s %s\n' "$stale_overlay_pid" "$(test_process_start_time "$stale_overlay_pid")" >"$keystroke_state"
rm -f "$OMARCHY_TEST_RECORDER_PROCESS_PID"
if stop_test_recording gpu-screen-recorder >/dev/null; then
  fail "--stop-recording succeeds without a recorder"
fi
wait_for_process_exit "$stale_overlay_pid" || fail "--stop-recording leaves stale owned overlay state running"
[[ ! -e $keystroke_state ]] || fail "--stop-recording leaves stale owned overlay state"
pass "--stop-recording cleans stale owned overlay state without a recorder"

"$recording_stub_bin/showmethekey-gtk" -k -A -C &
independent_overlay_pid=$!
sleep 0.05
rm -f "$OMARCHY_TEST_OVERLAY_STOPPED" "$OMARCHY_TEST_RECORDER_PROCESS_PID"
OMARCHY_TEST_BACKEND=gpu-screen-recorder \
  "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen --show-keystrokes
read -r owned_overlay_pid _ <"$keystroke_state"

printf '%s\n' -k -A -C >"$tmp_dir/expected-overlay-args"
cmp -s "$OMARCHY_TEST_OVERLAY_ARGS" "$tmp_dir/expected-overlay-args" || \
  fail "--show-keystrokes uses the documented Show Me The Key launch arguments" "$(diff -u "$tmp_dir/expected-overlay-args" "$OMARCHY_TEST_OVERLAY_ARGS")"
grep -Fx 'gpu-screen-recorder' "$OMARCHY_TEST_RECORDER_PROCESS_ARGS" >/dev/null || \
  fail "--show-keystrokes changes the gpu-screen-recorder backend"

grep -F 'including passwords' "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null || \
  fail "--show-keystrokes does not warn that password keystrokes will be recorded"
stop_test_recording gpu-screen-recorder >/dev/null
wait_for_process_exit "$owned_overlay_pid" || fail "stopping a recording leaves its Show Me The Key process running"
kill -0 "$independent_overlay_pid" 2>/dev/null || fail "stopping a recording kills an independently launched Show Me The Key process"
[[ ! -e $keystroke_state ]] || fail "stopping a recording leaves keystroke overlay state"
kill "$independent_overlay_pid"
wait_for_process_exit "$independent_overlay_pid" || fail "independent Show Me The Key test process did not exit"
pass "--show-keystrokes launches and cleans up only its owned overlay"

rm -f "$OMARCHY_TEST_OVERLAY_STOPPED" "$OMARCHY_TEST_RECORDER_PROCESS_PID"
if OMARCHY_TEST_BACKEND=gpu-screen-recorder \
  OMARCHY_TEST_RECORDER_FAIL=true \
  "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen --show-keystrokes; then
  fail "screen recording reports success when the recorder fails during startup"
fi
failed_start_overlay_pid=$(cat "$OMARCHY_TEST_OVERLAY_LAST_PID")
wait_for_process_exit "$failed_start_overlay_pid" || fail "recorder startup failure leaves its Show Me The Key process running"
[[ ! -e $keystroke_state ]] || fail "recorder startup failure leaves keystroke overlay state"
pass "recorder startup failure cleans up the owned keystroke overlay"

rm -f "$OMARCHY_TEST_RECORDER_PROCESS_PID" "$keystroke_state"
OMARCHY_TEST_BACKEND=gpu-screen-recorder \
  OMARCHY_TEST_RECORDER_NO_FILE=true \
  "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen --show-keystrokes &
starting_command_pid=$!
wait_for_file "$OMARCHY_TEST_RECORDER_PROCESS_PID" || fail "startup signal test did not launch the recorder"
wait_for_file "$keystroke_state" || fail "startup signal test did not save overlay state"
read -r starting_overlay_pid _ <"$keystroke_state"
starting_recorder_pid=$(cat "$OMARCHY_TEST_RECORDER_PROCESS_PID")
kill -TERM "$starting_command_pid"
wait "$starting_command_pid" 2>/dev/null || :
wait_for_process_exit "$starting_overlay_pid" || fail "a startup signal leaves the unhanded keystroke overlay running"
kill -TERM "$starting_recorder_pid" 2>/dev/null
wait_for_process_exit "$starting_recorder_pid" || fail "startup signal test recorder did not exit"
[[ ! -e $keystroke_state ]] || fail "a startup signal leaves unhanded overlay state"
pass "startup signal cleanup owns the overlay until recorder handoff"

rm -f "$OMARCHY_TEST_RECORDER_PROCESS_PID"
OMARCHY_TEST_BACKEND=gpu-screen-recorder \
  "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen --show-keystrokes
read -r watched_overlay_pid watched_overlay_started watched_recorder_pid watched_recorder_started <"$keystroke_state"
kill -TERM "$watched_recorder_pid"
wait_for_process_exit "$watched_recorder_pid" || fail "watchdog test recorder did not exit"
wait_for_process_exit "$watched_overlay_pid" || fail "recorder exit leaves its watched keystroke overlay running"
wait_for_file_removal "$keystroke_state" || fail "recorder exit leaves watched keystroke overlay state"
pass "detached watchdog cleans the exact overlay after unexpected recorder exit"

rm -f "$OMARCHY_TEST_RECORDER_PROCESS_PID"
OMARCHY_TEST_BACKEND=gpu-screen-recorder \
  "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen --show-keystrokes
read -r later_overlay_pid _ <"$keystroke_state"
"$ROOT/bin/omarchy-capture-screenrecording" \
  --keystroke-overlay-watchdog="$watched_overlay_pid:$watched_overlay_started:$watched_recorder_pid:$watched_recorder_started"
kill -0 "$later_overlay_pid" 2>/dev/null || fail "an old watchdog kills a later recording's keystroke overlay"
stop_test_recording gpu-screen-recorder >/dev/null
pass "old watchdogs cannot clean a later recording's overlay"

rm -f "$OMARCHY_TEST_RECORDER_PROCESS_PID"
OMARCHY_TEST_BACKEND=wf-recorder \
  "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen --show-keystrokes
grep -Fx 'wf-recorder' "$OMARCHY_TEST_RECORDER_PROCESS_ARGS" >/dev/null || \
  fail "--show-keystrokes changes the wf-recorder backend"
stop_test_recording wf-recorder >/dev/null
pass "--show-keystrokes preserves the wf-recorder backend"

keystroke_rules="$ROOT/default/hypr/apps/showmethekey.lua"
grep -F 'class = "^(one\\.alynx\\.showmethekey|showmethekey-gtk)$", title = "^Floating Window - Show Me The Key$"' "$keystroke_rules" >/dev/null || \
  fail "Show Me The Key window rule does not match its documented app IDs and title"
grep -F 'move = { "(monitor_w-window_w)/2", "monitor_h-window_h-40" }' "$keystroke_rules" >/dev/null || \
  fail "Show Me The Key window rule is not positioned near the bottom center"
grep -F 'float = true' "$keystroke_rules" >/dev/null &&
  grep -F 'pin = true' "$keystroke_rules" >/dev/null &&
  grep -F 'no_initial_focus = true' "$keystroke_rules" >/dev/null &&
  grep -F 'focus_on_activate = false' "$keystroke_rules" >/dev/null &&
  grep -F 'opacity = "1 1"' "$keystroke_rules" >/dev/null || \
  fail "Show Me The Key window rule does not float, pin, preserve focus, and force full opacity"
pass "Show Me The Key has a focused floating-window rule"
