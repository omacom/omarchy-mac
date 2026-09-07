#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

user_all="$ROOT/install/user/all.sh"
mic_leaf="$ROOT/install/user/hardware/apple/mic.sh"
headset_conf="$ROOT/default/wireplumber/wireplumber.conf.d/asahi-headset-mic.conf"
map_cmd="$ROOT/bin/omarchy-audio-asahi-mic-map"
hw_cmd="$ROOT/bin/omarchy-hw-apple"
autostart="$ROOT/default/hypr/autostart.lua"
migration=$(grep -rl 'Map the Asahi mic array to stereo' "$ROOT/migrations" | head -n 1 || true)

[[ -x $map_cmd ]] || fail "omarchy-audio-asahi-mic-map ships and is executable"
[[ -x $hw_cmd ]] || fail "omarchy-hw-apple ships and is executable"
[[ -f $mic_leaf ]] || fail "the Apple Silicon mic user leaf ships"
[[ -f $headset_conf ]] || fail "the headset-mic WirePlumber drop-in ships"
grep -Fq 'hardware/apple/mic.sh' "$user_all" ||
  fail "Apple Silicon mic mapping runs during user setup"
grep -Fq 'omarchy-audio-asahi-mic-map' "$autostart" ||
  fail "Hyprland start remaps the Asahi mic array"
[[ -n $migration ]] || fail "existing Apple Silicon installs get the mic mapping"
grep -Fq 'apple/audio.sh' "$migration" || fail "the migration retries speakersafetyd"
grep -Fq 'apple/mic.sh' "$migration" || fail "the migration maps the Asahi mic array"
pass "fresh and existing installs are wired to Asahi mic mapping"

grep -Fq 'HiFi__Headset__source' "$headset_conf" ||
  fail "the headset drop-in targets the unused jack mic"
pass "the headset drop-in targets the unused jack mic"

! grep -Fq 'move-source-output' "$map_cmd" ||
  fail "the mapper does not steal the DSP chain's capture"
pass "the mapper does not steal the DSP chain's capture"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
compatible="$test_tmp/compatible"
sink_created="$test_tmp/sink-created"
mkdir -p "$stub_bin"

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash

if [[ ${1:-} == "-m" ]]; then
  printf '%s\n' "${TEST_ARCH:-x86_64}"
else
  exec /usr/bin/uname "$@"
fi
SH

cat >"$stub_bin/pactl" <<'SH'
#!/bin/bash

printf 'pactl' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"

case "${1:-}" in
list)
  if [[ ${2:-} == "short" && ${3:-} == "sources" ]]; then
    printf '58\teffect_output.j313-mic\tPipeWire\ts32le 1ch 48000Hz\tSUSPENDED\n'
  elif [[ ${2:-} == "short" && ${3:-} == "sinks" ]]; then
    printf '59\taudio_effect.j313-convolver\tPipeWire\tfloat32le 2ch 48000Hz\tSUSPENDED\n'
    if [[ -e $SINK_CREATED ]]; then
      printf '60\tomarchy_asahi_mic\tPipeWire\tfloat32le 2ch 48000Hz\tSUSPENDED\n'
    fi
  fi
  ;;
load-module)
  touch "$SINK_CREATED"
  echo 42
  ;;
esac
SH

cat >"$stub_bin/pw-link" <<'SH'
#!/bin/bash

printf 'pw-link' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"

case "${1:-}" in
-o)
  printf '%s\n' "effect_output.j313-mic:capture_AUX0"
  ;;
-i)
  printf '%s\n' "omarchy_asahi_mic:playback_FL"
  printf '%s\n' "omarchy_asahi_mic:playback_FR"
  ;;
esac
SH

chmod +x "$stub_bin"/*

run_hw() {
  PATH="$stub_bin:$ROOT/bin:$PATH" \
    TEST_ARCH="$1" \
    OMARCHY_APPLE_COMPATIBLE="$compatible" \
    "$hw_cmd"
}

: >"$compatible"
run_hw x86_64 &&
  fail "omarchy-hw-apple rejects non-aarch64 hosts" ||
  pass "omarchy-hw-apple rejects non-aarch64 hosts"

printf '%s\0' 'linux,dummy' >"$compatible"
run_hw aarch64 &&
  fail "omarchy-hw-apple rejects non-Apple aarch64 hosts" ||
  pass "omarchy-hw-apple rejects non-Apple aarch64 hosts"

printf '%s\0' 'apple,j313' >"$compatible"
run_hw aarch64 ||
  fail "omarchy-hw-apple detects Apple Silicon"
pass "omarchy-hw-apple detects Apple Silicon"

: >"$calls"
PATH="$stub_bin:$ROOT/bin:$PATH" \
  TEST_ARCH=x86_64 \
  OMARCHY_APPLE_COMPATIBLE="$compatible" \
  TEST_LOG="$calls" \
  SINK_CREATED="$sink_created" \
  "$map_cmd"
[[ ! -s $calls ]] || fail "omarchy-audio-asahi-mic-map is a no-op off Apple Silicon" "$(cat "$calls")"
pass "omarchy-audio-asahi-mic-map is a no-op off Apple Silicon"

: >"$calls"
rm -f "$sink_created"
PATH="$stub_bin:$ROOT/bin:$PATH" \
  TEST_ARCH=aarch64 \
  OMARCHY_APPLE_COMPATIBLE="$compatible" \
  TEST_LOG="$calls" \
  SINK_CREATED="$sink_created" \
  "$map_cmd" || fail "the mapper succeeds on Apple Silicon with DSP present"

grep -Fq $'pactl\tload-module\tmodule-null-sink' "$calls" ||
  fail "the mapper creates a stereo null sink" "$(cat "$calls")"
grep -Fq $'pw-link\teffect_output.j313-mic:capture_AUX0\tomarchy_asahi_mic:playback_FL' "$calls" ||
  fail "the mapper copies AUX0 onto FL" "$(cat "$calls")"
grep -Fq $'pw-link\teffect_output.j313-mic:capture_AUX0\tomarchy_asahi_mic:playback_FR' "$calls" ||
  fail "the mapper copies AUX0 onto FR" "$(cat "$calls")"
grep -Fq $'pactl\tset-default-sink\taudio_effect.j313-convolver' "$calls" ||
  fail "the mapper restores the speaker convolver as the default sink" "$(cat "$calls")"
grep -Fq $'pactl\tset-default-source\tomarchy_asahi_mic.monitor' "$calls" ||
  fail "the mapper uses the stereo monitor as the default source" "$(cat "$calls")"
! grep -Fq 'move-source-output' "$calls" ||
  fail "the mapper does not move existing source-outputs" "$(cat "$calls")"
pass "the mapper duplicates AUX0 onto a stereo default source"

: >"$calls"
PATH="$stub_bin:$ROOT/bin:$PATH" \
  TEST_ARCH=aarch64 \
  OMARCHY_APPLE_COMPATIBLE="$compatible" \
  TEST_LOG="$calls" \
  SINK_CREATED="$sink_created" \
  "$map_cmd" || fail "the mapper is idempotent"
! grep -Fq $'pactl\tload-module\tmodule-null-sink' "$calls" ||
  fail "an existing stereo sink is reused" "$(cat "$calls")"
pass "an existing stereo sink is reused"

fake_home="$test_tmp/home"
mkdir -p "$fake_home"
: >"$calls"
PATH="$stub_bin:$ROOT/bin:$PATH" \
  HOME="$fake_home" \
  OMARCHY_PATH="$ROOT" \
  TEST_ARCH=aarch64 \
  OMARCHY_APPLE_COMPATIBLE="$compatible" \
  TEST_LOG="$calls" \
  SINK_CREATED="$sink_created" \
  bash -euo pipefail -c 'source "$1"' bash "$mic_leaf"
[[ -f $fake_home/.config/wireplumber/wireplumber.conf.d/asahi-headset-mic.conf ]] ||
  fail "user setup copies the headset-mic drop-in"
pass "user setup copies the headset-mic drop-in"
