#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
"$ROOT/install" "$stage"
conf=$stage/usr/share/pipewire/pipewire.conf.d/asahi-device-names.conf
[[ -f $conf ]] || fail 'the device names ship as a PipeWire daemon fragment'
python3 - "$conf" <<'PY'
import re
import sys
text = re.sub(r'#[^\n]*', '', open(sys.argv[1]).read())
assert text.strip().startswith('node.rules = ['), 'node.rules is the only section'
rules = []
for matches, props in re.findall(r'matches = \[(.*?)\]\s*actions = \{\s*update-props = \{(.*?)\}', text, re.S):
    names = [value.replace('\\\\', '\\') for value in re.findall(r'node\.name = "([^"]*)"', matches)]
    assert names and len(names) == len(re.findall(r'\{', matches)), matches
    props = dict(re.findall(r'(\S+) = "([^"]*)"', props))
    assert list(props) == ['node.description'], props
    rules.append((names, props['node.description']))
assert len(rules) == text.count('update-props'), 'every rule parsed'
def matched(pattern, name):
    # PipeWire treats "~" as an unanchored regular expression search.
    return re.search(pattern[1:], name) is not None if pattern.startswith('~') else pattern == name
def description(name):
    found = [value for names, value in rules if any(matched(pattern, name) for pattern in names)]
    assert len(found) <= 1, (name, found)
    return found[0] if found else None
# Every node asahi-audio 4.x names, by the graphs its rules load.
laptops = '293 313 314 316 413 414 415 416 493 504 514 516 613 615'.split()
for board in laptops:
    assert description('audio_effect.j%s-convolver' % board) == 'MacBook Speakers', board
    assert description('effect_output.j%s-mic' % board) == 'MacBook Microphone (Mono)', board
    # The DSP's own streams keep their names: the desktop shell hides them.
    assert description('effect_output.j%s-convolver' % board) is None, board
    assert description('audio_effect.j%s-mic' % board) is None, board
for desktop in ('mini', 'studio'):
    assert description('audio_effect.%s-convolver' % desktop) == 'Built-in Speakers', desktop
assert description('alsa_output.platform-sound.HiFi__Headphones__sink') == 'Headphones'
assert description('alsa_input.platform-sound.HiFi__Headset__source') == 'Headset Microphone'
# Nothing else is renamed, however close its name.
for name in ('omarchy_asahi_mic', 'effect_output.eq6', 'audio_effect.j416-convolver-eq', 'my-audio_effect.j416-convolver',
             'effect_output.j416-mic.monitor', 'alsa_output.platform-sound.RawSpeakers', 'alsa_input.platform-sound.RawMics',
             'alsa_output.pci-0000_00_1f.3.analog-stereo', 'alsa_input.pci-0000_00_1f.3.analog-stereo'):
    assert description(name) is None, name
PY
pass 'Apple audio devices are named by family, without board codes, and nothing else is renamed'
