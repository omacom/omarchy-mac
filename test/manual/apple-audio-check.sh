#!/bin/bash

# Hardware check for audio on an Apple Silicon Mac: the protected speaker stack,
# speaker safety and its single owner, the no-suspend policy and the microphone
# mapping. Not part of ./test/shell: it needs the real Mac. Run it as the desktop
# user, from a terminal in the session or over SSH:
#
#   bash test/manual/apple-audio-check.sh [--no-sound]
#
# Read-only apart from a 3 s microphone capture and a 2 s tone on the default
# sink, both in memory: listen for the tone and for a pop when it starts and
# stops. --no-sound skips both. The kernel log comes from the system journal,
# through sudo -n when the user cannot read it.

set -u
sound=1
[[ ${1:-} == "--no-sound" ]] && sound=0
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
status=0

check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS $description"
  else
    echo "FAIL $description"
    status=1
  fi
}

safety_presets() {
  grep -lE '^[[:space:]]*enable[[:space:]]+speakersafetyd' \
    /usr/lib/systemd/system-preset/*.preset /etc/systemd/system-preset/*.preset 2>/dev/null
}

safety_links() {
  find /etc/systemd/system -path '*.wants/speakersafetyd.service' 2>/dev/null
}

only_omarchy_mac_presets() {
  local presets
  presets=$(safety_presets) || return 1
  # shellcheck disable=SC2086
  [[ $(pacman -Qqo $presets | sort -u) == omarchy-mac ]]
}

enabled_once() {
  [[ $(safety_links | wc -l) == 1 ]]
}

# snd-soc-macaudio logs this once speakersafetyd has lifted the -100 dB lock.
amps_unlocked() {
  local message='Speaker volumes unlocked'
  journalctl -k -b --no-pager -q 2>/dev/null | grep -q "$message" ||
    sudo -n journalctl -k -b --no-pager -q 2>/dev/null | grep -q "$message"
}

sinks_never_suspend() {
  pw-dump | python3 -c "
import json, sys
nodes = [o['info']['props'] for o in json.load(sys.stdin) if o.get('type', '').endswith(':Node')]
alsa = [p for p in nodes if p.get('media.class') == 'Audio/Sink' and str(p.get('api.alsa.path', '')).startswith('hw:AppleJ') and str(p.get('api.alsa.path', '')).endswith((',0', ',1'))]
sys.exit(not alsa or any(int(p.get('session.suspend-timeout-seconds', 5)) != 0 for p in alsa))
"
}

source_has_signal() {
  timeout 3 parec --device="$1" --raw --format=s16le --channels=2 --rate=48000 | python3 -c "
import array, sys
samples = array.array('h', sys.stdin.buffer.read())
peak = max(map(abs, samples)) if samples else 0
print('peak', peak, file=sys.stderr)
sys.exit(peak < 8)
"
}

check "audio stack installed" pacman -Q omarchy-mac alsa-ucm-conf-asahi asahi-audio speakersafetyd rtkit pipewire-alsa
check "speakersafetyd enabled and active" bash -c 'systemctl is-enabled --quiet speakersafetyd && systemctl is-active --quiet speakersafetyd'
echo "speakersafetyd presets: $(safety_presets | tr '\n' ' ')"
echo "speakersafetyd enable links: $(safety_links | tr '\n' ' ')"
check "only omarchy-mac presets speakersafetyd" only_omarchy_mac_presets
check "speakersafetyd enabled by exactly one link" enabled_once
check "speaker amps unlocked this boot" amps_unlocked
check "speaker DSP sink present" bash -c "pactl list short sinks | grep -q convolver"
check "speaker and headphone sinks never suspend" sinks_never_suspend
check "mic mapper running" systemctl --user is-active --quiet omarchy-asahi-mic.service
source=$(pactl get-default-source)
echo "default source: $source"
journalctl --user -b -u omarchy-asahi-mic.service --no-pager | tail -n 5
(( sound )) || exit $status
check "default source carries microphone signal" source_has_signal "$source"
echo "Playing a 2 s tone on the default sink ($(pactl get-default-sink))"
python3 -c "
import math, struct, sys
sys.stdout.buffer.write(b''.join(struct.pack('<hh', v, v) for v in (int(3000 * math.sin(2 * math.pi * 440 * i / 48000)) for i in range(96000))))
" | pacat --raw --format=s16le --channels=2 --rate=48000
echo "Listen: tone audible, no pop at start or stop. Record the result by hand."
exit $status
