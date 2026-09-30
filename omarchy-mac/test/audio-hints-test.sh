#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
"$ROOT/install" "$stage"
hints=$stage/usr/share/omarchy-platform/audio.json
[[ -f $hints && ! -L $hints ]] || fail 'the audio hints are staged in the platform root'
python3 - "$hints" <<'PY'
import json
import re
import sys
data = json.load(open(sys.argv[1]))
assert sorted(data) == ['hidden', 'replaced'], sorted(data)
# The runtime matches each pattern against a whole node.name as a JavaScript
# regular expression; these use nothing Python reads differently.
hidden = [re.compile(pattern) for pattern in data['hidden']]
replaced = [(re.compile(entry['node']), re.compile(entry['by'])) for entry in data['replaced']]
assert all(sorted(entry) == ['by', 'node'] for entry in data['replaced'])
def hides(name, present):
    if any(pattern.fullmatch(name) for pattern in hidden):
        return True
    return any(node.fullmatch(name) and any(other != name and by.fullmatch(other) for other in present) for node, by in replaced)
laptops = '293 313 314 316 413 414 415 416 493 504 514 516 613 615'.split()
for board in laptops:
    mic = 'effect_output.j%s-mic' % board
    assert hides('effect_output.j%s-convolver' % board, []), board
    assert hides('audio_effect.j%s-mic' % board, []), board
    assert not hides('audio_effect.j%s-convolver' % board, []), 'the speakers stay: ' + board
    assert hides(mic, [mic, 'omarchy_asahi_mic']), 'the mono microphone hides behind its mapping: ' + board
    assert not hides(mic, [mic]), 'the mono microphone stays without its mapping: ' + board
for desktop in ('mini', 'studio'):
    assert hides('effect_output.%s-convolver' % desktop, []), desktop
    assert not hides('audio_effect.%s-convolver' % desktop, []), desktop
assert hides('alsa_output.platform-sound.RawSpeakers', []) and hides('alsa_input.platform-sound.RawMics', [])
present = ['omarchy_asahi_mic', 'effect_output.j416-mic']
for name in ('omarchy_asahi_mic', 'alsa_output.platform-sound.HiFi__Headphones__sink', 'alsa_input.platform-sound.HiFi__Headset__source',
             'effect_output.eq6', 'effect_output.j416-convolver-eq', 'my-audio_effect.j416-mic', 'effect_output.j416-mic.monitor',
             'alsa_output.platform-sound.RawSpeakers.monitor', 'omarchy-audio-level', 'Firefox'):
    assert not hides(name, present), name
PY
pass 'the audio hints hide asahi-audio DSP internals, and the mono microphone only behind its mapping'
