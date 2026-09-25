#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

require_command ffmpeg
require_command ffprobe

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A 96 kHz recording switches the Asahi speaker PCM to 96 kHz on playback, and
# speakersafetyd then locks the amps. wf-recorder writes 48 kHz; the loudness
# pass must keep it.
source <(sed -n '/^finalize_recording() {/,/^}/p' "$ROOT/bin/omarchy-capture-screenrecording")
recording="$work/recording.mp4"
ffmpeg -loglevel error -f lavfi -i testsrc=size=64x64:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 1 -c:v libx264 -c:a aac -ar 48000 "$recording"
RECORDING_FILE="$work/latest"
echo "$recording" >"$RECORDING_FILE"
finalize_recording

# The pass trims the first 0.1 s, so a shorter file proves it ran.
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$recording")
awk -v d="$duration" 'BEGIN { exit !(d < 0.95) }' || fail "the loudness pass processed the recording" "$duration"
rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$recording")
[[ $rate == "48000" ]] || fail "the finalized recording keeps 48 kHz audio" "$rate"
pass "the finalized recording keeps 48 kHz audio"
