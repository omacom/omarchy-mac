#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
python3 - "$ROOT" <<'PY'
import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from unittest import mock
root = Path(sys.argv[1])
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader('mic', str(root / 'bin/omarchy-audio-asahi-mic-map'))
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
DSP = 'effect_output.j414-mic'
VIRTUAL = 'module-null-sink', 'media.class=Audio/Source/Virtual sink_name=omarchy_asahi_mic channels=2 sink_properties=' + m.OWNER + '=existing'
LEGACY_MODULE = dict(index='41', name='module-null-sink', argument='sink_name=omarchy_asahi_mic channels=2 sink_properties=device.description=AsahiMicrophone ' + m.OWNER + '=old')
def obj(name, value=27525, mute=True):
    return dict(name=name, volume={'front-left': {'value': value}, 'front-right': {'value': value}}, mute=mute)
class Audio:
    def __init__(self, existing=False, default=DSP):
        self.calls = []; self.default = default; self.existing = existing
        self.mapping = obj(m.MAPPING)
        self.module = dict(index='40', name=VIRTUAL[0], argument=VIRTUAL[1]) if existing else None
        self.legacy = None
        self.linked = {}; self.missing = None; self.fail_link = None; self.fail_module = False
        self.fail_query = False; self.fail_graph = False; self.concurrent = False
        self.next_id = 100; self.auto_input = False; self.initial_input = default; self.no_dsp = False
        self.carries_signal = True; self.probes = []; self.probe_choice = None
        self.notices = []; self.feeds = {m.MAPPING}; self.routes = 0; self.route_choice = None
        self.stamp = None; self.restarts = 0; self.link_error = 'link rejected after partial creation'
        self.cards = [dict(name='alsa_card.platform-sound', active_profile='HiFi')]
    def restart_session_manager(self, reason): self.restarts += 1; return 0
    def objects(self, kind):
        if self.fail_query: raise RuntimeError('live Pulse query failed')
        if kind == 'sources':
            legacy = [copy.deepcopy(self.legacy[1])] if self.legacy else []
            return ([] if self.no_dsp else [obj(DSP)]) + [obj('usb-mic')] + ([copy.deepcopy(self.mapping)] if self.existing else []) + legacy
        if kind == 'sinks': return [obj('speakers')] + ([copy.deepcopy(self.legacy[0])] if self.legacy else [])
        if kind == 'cards': return copy.deepcopy(self.cards)
        raise AssertionError(kind)
    def modules(self):
        return [module for module in (self.module, LEGACY_MODULE if self.legacy else None) if module]
    def graph(self):
        if self.fail_graph: raise RuntimeError('live graph query failed')
        nodes = [dict(id=1, type='PipeWire:Interface:Node', info={'props': {'node.name': DSP}})]
        ports = [(11, 1, 'capture_AUX0')]
        if self.existing:
            nodes.append(dict(id=2, type='PipeWire:Interface:Node', info={'props': {'node.name': m.MAPPING}}))
            ports += [(21, 2, 'input_FL'), (22, 2, 'input_FR')]
        for id_, node, name in ports:
            if name != self.missing: nodes.append(dict(id=id_, type='PipeWire:Interface:Port', info={'props': {'node.id': node, 'port.name': name}}))
        for id_, (input_, owner) in self.linked.items():
            nodes.append(dict(id=id_, type='PipeWire:Interface:Link', info={'output-port-id': 11, 'input-port-id': input_, 'state': 'paused', 'props': {m.OWNER: owner}}))
        if self.concurrent and len(self.linked) == 2: self.default = 'usb-mic'
        return nodes
    def pause(self): pass
    def notify(self, *args): self.notices.append(args)
    def signal(self, source):
        self.probes.append(source)
        if self.probe_choice is not None: self.default = self.probe_choice
        return self.carries_signal
    def route(self):
        self.routes += 1
        if self.route_choice is not None: self.default = self.route_choice
        return self.feeds
    def run(self, *args):
        self.calls.append(args)
        if args[0] == 'pw-link':
            if args[1] == '-d': self.linked.pop(int(args[2])); return ''
            input_ = int(args[-1]); self.next_id += 1
            self.linked[self.next_id] = (input_, json.loads(args[4])[m.OWNER])
            if self.fail_link == input_: raise RuntimeError(self.link_error)
            return ''
        assert args[0] == 'pactl', args
        command = args[1]
        if command == 'get-default-source': return self.default
        if command == 'load-module':
            if self.fail_module: raise RuntimeError('module failed')
            self.module = dict(index='42', name='module-null-sink', argument=' '.join(args[3:]))
            assert args[2] == 'module-null-sink' and 'media.class=Audio/Source/Virtual' in args[3:], args
            self.existing = True
            if self.auto_input: self.default = m.MAPPING
            self.mapping = obj(m.MAPPING, 65536, False)
            return '42'
        if command == 'unload-module':
            if self.legacy and args[2] == LEGACY_MODULE['index']:
                self.legacy = None
                if self.default == m.LEGACY: self.default = 'headphones.monitor'
                return ''
            self.existing = False; self.module = None; self.linked = {}
            if self.default == m.MAPPING: self.default = self.initial_input
            return ''
        if command == 'set-default-source': self.default = args[2]; return ''
        assert args[2] == m.MAPPING, 'DSP/user device must never be modified'
        if command == 'set-source-volume':
            self.mapping['volume'] = {str(i): {'value': int(value)} for i, value in enumerate(args[3:])}; return ''
        if command == 'set-source-mute': self.mapping['mute'] = args[3] == '1'; return ''
        raise AssertionError(args)
with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    def state():
        path = directory / ('state-' + str(len(list(directory.iterdir()))) + '.json'); return path
    # Numeric IDs may be recycled while the transaction is running. Old links
    # alone are not proof that the named DSP and stereo ports still own them.
    for missing in ('capture_AUX0', 'input_FL', 'input_FR'):
        class RecreatedAudio(Audio):
            def graph(self):
                graph = super().graph()
                if len(self.linked) == 2:
                    for item in graph:
                        props = item.get('info', {}).get('props', {})
                        if props.get('port.name') == missing:
                            props['port.name'] = 'unrelated-recycled-port'
                return graph
        audio = RecreatedAudio()
        try:
            m.reconcile(audio, state())
        except RuntimeError as error:
            assert 'endpoints changed' in str(error)
        else:
            raise AssertionError('recycled endpoint IDs accepted')
        assert audio.default == DSP and not audio.existing and not audio.linked
        assert ('pactl', 'set-default-source', m.MAPPING) not in audio.calls
    # A choice made during the final graph query must be observed.
    class FinalQueryChoice(Audio):
        def __init__(self):
            super().__init__()
            self.choice_injected = False
        def graph(self):
            graph = super().graph()
            if self.probes:
                self.default = 'usb-mic'
                self.choice_injected = True
            return graph
    audio = FinalQueryChoice()
    m.reconcile(audio, state())
    assert audio.choice_injected and audio.default == 'usb-mic'
    assert ('pactl', 'set-default-source', m.MAPPING) not in audio.calls
    for selected in (DSP, 'usb-mic', m.MAPPING):
        audio = Audio(True, selected); audio.linked = {90: (21, 'existing'), 91: (22, 'existing')}
        before = copy.deepcopy(audio.mapping); saved = state()
        m.reconcile(audio, saved); m.reconcile(audio, saved)
        assert audio.mapping == before, '42 percent and mute must survive repeat mapping'
        assert not any('volume' in call[1] or 'mute' in call[1] for call in audio.calls)
        assert audio.default == (m.MAPPING if selected == DSP else selected)
        assert sum(call[1] == 'set-default-source' for call in audio.calls) == (1 if selected == DSP else 0)
    # A mapping that carries only digital silence (#505) never becomes the
    # default input, and a default already left on it returns to the DSP.
    # The mapping itself stays, so events do not rebuild it.
    for selected in (DSP, ''):
        audio = Audio(default=selected); audio.carries_signal = False
        try: m.reconcile(audio, state())
        except RuntimeError as error: assert 'no signal' in str(error), error
        else: raise AssertionError('a silent mapping must be reported')
        assert audio.default == selected and audio.probes == [m.MAPPING]
        assert audio.existing and len(audio.linked) == 2, 'a silent mapping must not be rolled back'
    def mapped(default, signal=True, mute=False):
        audio = Audio(True, default); audio.linked = {90: (21, 'existing'), 91: (22, 'existing')}
        audio.mapping = obj(m.MAPPING, 65536, mute)
        audio.carries_signal = signal
        return audio
    audio = mapped(m.MAPPING, signal=False)
    try: m.reconcile(audio, state())
    except RuntimeError as error: assert 'no signal' in str(error), error
    else: raise AssertionError('a silent default must be reported')
    assert audio.default == DSP and audio.linked == {90: (21, 'existing'), 91: (22, 'existing')}
    audio = mapped(m.MAPPING)
    m.reconcile(audio, state())
    assert audio.default == m.MAPPING and audio.probes == [m.MAPPING], 'a live mapped default stays'
    # A muted mapping is the user's microphone mute (the mute key mutes the
    # default source): never sampled, never swapped for the unmuted DSP, and
    # still selected after a default reset.
    for selected in (m.MAPPING, DSP):
        audio = mapped(selected, signal=False, mute=True)
        m.reconcile(audio, state())
        assert audio.default == m.MAPPING and not audio.probes, selected
        # Muting while the mapping is sampled silences it; that is still a mute.
        audio = mapped(selected, signal=False)
        sample = audio.signal
        audio.signal = lambda source, audio=audio, sample=sample: (audio.mapping.update(mute=True), sample(source))[1]
        m.reconcile(audio, state())
        assert audio.default == m.MAPPING and audio.probes == [m.MAPPING], selected
    # A sample that could not be taken changes nothing and is reported.
    for selected in (DSP, m.MAPPING):
        audio = mapped(selected, signal=None)
        try: m.reconcile(audio, state())
        except RuntimeError as error: assert 'Could not sample' in str(error), error
        else: raise AssertionError('an unsampled mapping must be reported')
        assert audio.default == selected
    # The supervisor samples a default mapping once, not on every event.
    checked = set(); audio = mapped(m.MAPPING)
    m.reconcile(audio, state(), checked=checked); m.reconcile(audio, state(), checked=checked)
    assert audio.probes == [m.MAPPING] and audio.default == m.MAPPING and audio.routes == 1
    audio = mapped(m.MAPPING); m.reconcile(audio, state()); m.reconcile(audio, state())
    assert audio.probes == [m.MAPPING, m.MAPPING]
    # After an audio restart the mapping is rebuilt, possibly on recycled port
    # IDs, while the configured default still names it.
    audio = Audio(default=m.MAPPING); audio.carries_signal = False
    try: m.reconcile(audio, state(), checked=checked)
    except RuntimeError as error: assert 'no signal' in str(error), error
    else: raise AssertionError('a rebuilt silent mapping must be sampled')
    assert audio.probes == [m.MAPPING] and audio.default == DSP
    # Other inputs are the user's; the microphone is not even opened for them.
    audio = Audio(default='usb-mic'); audio.carries_signal = False
    m.reconcile(audio, state())
    assert audio.default == 'usb-mic' and not audio.probes and not audio.routes
    # A choice made while the mapping is sampled wins over the result.
    for signal in (True, False):
        for selected in (DSP, m.MAPPING):
            audio = mapped(selected, signal); audio.probe_choice = 'usb-mic'
            try: m.reconcile(audio, state())
            except RuntimeError: assert not signal
            else: assert signal, 'a silent mapping must be reported'
            assert audio.default == 'usb-mic', (signal, selected)
    audio = Audio(default='usb-mic'); audio.no_dsp = True
    try: m.reconcile(audio, state())
    except m.Deferred: pass
    else: raise AssertionError('Apple desktop without a mic array should defer safely')
    assert audio.calls == [('pactl', 'get-default-source')] and audio.default == 'usb-mic'
    # #99: apps that name no device follow the default route. A selected mapping
    # is checked once through that route; if WirePlumber links such a capture
    # elsewhere, the DSP becomes the default instead.
    checked = set(); audio = Audio(); m.reconcile(audio, state(), checked=checked)
    assert audio.default == m.MAPPING and audio.routes == 1
    m.reconcile(audio, state(), checked=checked)
    assert audio.routes == 1, 'the route is checked once per mapping'
    audio = Audio(); audio.feeds = {'audio_effect.j416-convolver.monitor'}
    try: m.reconcile(audio, state())
    except RuntimeError as error: assert 'reach audio_effect.j416-convolver.monitor' in str(error), error
    else: raise AssertionError('a misrouted default must be reported')
    assert audio.default == DSP
    checked = set(); audio = Audio(); audio.feeds = {'audio_effect.j416-convolver.monitor'}
    for attempt in range(3):
        try: m.reconcile(audio, state(), checked=checked)
        except RuntimeError: pass
    assert audio.default == DSP and audio.routes == 1, 'a misrouted mapping is not reselected on every event'
    stalled = [dict(id=1, type='PipeWire:Interface:Node', info={'props': {'node.name': m.MAPPING}}),
               dict(id=2, type='PipeWire:Interface:Node', info={'props': {'node.name': m.ROUTE_CLIENT}}),
               dict(id=41, type='PipeWire:Interface:Link', info={'output-node-id': 1, 'input-node-id': 2, 'state': 'init'}),
               dict(id=42, type='PipeWire:Interface:Link', info={'output-node-id': 9, 'input-node-id': 2, 'state': 'active'}),
               dict(id=43, type='PipeWire:Interface:Link', info={'output-node-id': 1, 'input-node-id': 2, 'state': 'error'})]
    assert m.sources_of(stalled, m.ROUTE_CLIENT) == {m.MAPPING}, 'unknown nodes and failed links are not feeds'
    audio = Audio(); audio.feeds = None
    m.reconcile(audio, state())
    assert audio.default == m.MAPPING, 'an unknown route changes nothing'
    audio = Audio(); audio.feeds = {'speakers.monitor'}; audio.route_choice = 'usb-mic'
    try: m.reconcile(audio, state())
    except RuntimeError: pass
    assert audio.default == 'usb-mic', 'a choice made during the route check wins'
    graph = [dict(id=1, type='PipeWire:Interface:Node', info={'props': {'node.name': m.MAPPING}}),
             dict(id=2, type='PipeWire:Interface:Node', info={'props': {'node.name': 'parec', 'application.name': m.ROUTE_CLIENT}}),
             dict(id=3, type='PipeWire:Interface:Node', info={'props': {'node.name': 'other'}}),
             dict(id=11, type='PipeWire:Interface:Port', info={'props': {'node.id': 1}}),
             dict(id=21, type='PipeWire:Interface:Port', info={'props': {'node.id': 2}}),
             dict(id=31, type='PipeWire:Interface:Port', info={'props': {'node.id': 3}}),
             dict(id=41, type='PipeWire:Interface:Link', info={'output-port-id': 11, 'input-port-id': 21}),
             dict(id=42, type='PipeWire:Interface:Link', info={'output-port-id': 11, 'input-port-id': 31})]
    assert m.sources_of(graph, m.ROUTE_CLIENT) == {m.MAPPING}
    # An earlier version mapped into a null sink whose monitor was the default
    # input. It is replaced by the source, keeping its selection and its gain
    # (the two controls in series, and a mute on either side).
    for selected, expected in ((m.LEGACY, m.MAPPING), ('usb-mic', 'usb-mic')):
        audio = Audio(default=selected)
        audio.legacy = (obj(m.MAPPING, 32768, False), obj(m.LEGACY, 65536, True))
        saved = state(); m.reconcile(audio, saved)
        assert ('pactl', 'unload-module', '41') in audio.calls and audio.legacy is None
        assert audio.existing and audio.default == expected, (selected, audio.default)
        assert m.gain(audio.mapping) == {'volume': [32768, 32768], 'mute': True}
        assert json.loads(saved.read_text()) == {'source': {'volume': [32768, 32768], 'mute': True}}
    # With the array missing the old mapping stays until it returns; a failure
    # after the swap still leaves a working default that the next pass maps.
    audio = Audio(default=m.LEGACY); audio.no_dsp = True
    audio.legacy = (obj(m.MAPPING, 65536, False), obj(m.LEGACY, 65536, False))
    try: m.reconcile(audio, state())
    except m.Deferred: pass
    assert audio.legacy and audio.default == m.LEGACY
    audio.no_dsp = False; audio.missing = 'input_FR'; saved = state()
    try: m.reconcile(audio, saved)
    except RuntimeError: pass
    else: raise AssertionError('missing port accepted')
    assert audio.legacy is None and audio.default == DSP
    audio.missing = None; m.reconcile(audio, saved)
    assert audio.default == m.MAPPING
    audio = Audio(); audio.legacy = (obj(m.MAPPING), obj(m.LEGACY))
    stranger = dict(LEGACY_MODULE, argument='sink_name=omarchy_asahi_mic')
    audio.modules = lambda: [stranger]
    try: m.reconcile(audio, state())
    except RuntimeError as error: assert 'does not own' in str(error), error
    else: raise AssertionError('a foreign sink must not be replaced')
    assert not any(call[1] == 'unload-module' for call in audio.calls if call[0] == 'pactl')
    audio = Audio(True); audio.module = dict(index='40', name='module-null-sink', argument='sink_name=omarchy_asahi_mic media.class=Audio/Source/Virtual')
    try: m.reconcile(audio, state())
    except RuntimeError as error: assert 'does not own' in str(error), error
    else: raise AssertionError('a foreign source must not be mapped into')
    assert not audio.linked
    legacy_state = state(); legacy_state.write_text(json.dumps({'sink': {'volume': [65536, 65536], 'mute': False}, 'monitor': {'volume': [32768, 32768], 'mute': False}}))
    audio = Audio(); m.reconcile(audio, legacy_state)
    assert m.gain(audio.mapping) == {'volume': [32768, 32768], 'mute': False}, 'legacy saved gain carries over'
    # The array's DSP can vanish after mapping (#99: WirePlumber left its
    # filter half-built on the M2 Max). The mapping then carries silence:
    # hand capture to a plugged-in real input rather than WirePlumber's
    # fallback (a monitor), tell the user once the loss lasts, and select the
    # mapping again when the array returns unless the user chose otherwise.
    def source(name, priority, klass='sound', available=None):
        ports = [{'name': '[In] Port', 'availability': available}] if available else []
        return dict(name=name, ports=ports, active_port='[In] Port' if available else None, monitor_source='',
                    properties={'priority.session': str(priority), 'device.class': klass}, volume={}, mute=False)
    unplugged = source('headset', 1, available='not available')
    plugged = source('headset', 1, available='available')
    usb = source('usb-mic', 5)
    other = source('other-mic', 0)
    headphones_monitor = dict(source('headphones.monitor', 1000, 'monitor'), monitor_source='headphones')
    raw = source('alsa_input.platform-sound.RawMics', 2000)
    class LostDsp(Audio):
        inputs = [unplugged]; ignored = ()
        def objects(self, kind):
            if kind == 'sources':
                return ([] if self.no_dsp else [obj(DSP)]) + [headphones_monitor, raw, *self.inputs] + ([copy.deepcopy(self.mapping)] if self.existing else [])
            return super().objects(kind)
        def run(self, *args):
            if args[1:2] == ('set-default-source',) and args[2] in self.ignored:
                self.calls.append(args); return ''
            return super().run(*args)
    def lost(inputs=(usb, other)):
        m.outage.update(since=None, notified=False, repaired=False)
        audio = LostDsp(True, m.MAPPING); audio.linked = {90: (21, 'existing'), 91: (22, 'existing')}
        audio.mapping = obj(m.MAPPING, 65536, False)
        audio.inputs = [dict(item) for item in inputs]; audio.no_dsp = True
        return audio
    def deferred(audio, saved):
        try: m.reconcile(audio, saved)
        except m.Deferred: pass
        else: raise AssertionError('a missing array must defer')
    def marker(saved):
        return m.claim(saved)
    assert m.real_inputs([obj(m.MAPPING), usb]) == ['usb-mic'], 'the mapping is never its own fallback'
    later = time.monotonic() + m.OUTAGE_GRACE + 1
    for inputs, expected in (([unplugged], m.MAPPING), ([unplugged, usb], 'usb-mic'), ([plugged], 'headset')):
        audio = lost(inputs); saved = state()
        deferred(audio, saved)
        assert audio.default == expected, audio.default
        assert marker(saved) == (None if expected == m.MAPPING else expected)
        assert not audio.notices and m.outage_due() is not None, 'a fresh loss is not announced yet'
        # A lasting loss first restarts WirePlumber (#1028 leaves the rebuilt
        # graph hidden), then is announced once if it outlasts that too.
        with mock.patch.object(m.time, 'monotonic', return_value=later):
            deferred(audio, saved); deferred(audio, saved)
        assert audio.restarts == 1 and not audio.notices, 'a lasting loss restarts WirePlumber once before any notice'
        assert m.recheck['at'] is not None, 'a repair schedules a look at the rebuilt graph'
        m.recheck['at'] = None
        with mock.patch.object(m.time, 'monotonic', return_value=later + m.OUTAGE_GRACE + 1):
            deferred(audio, saved); deferred(audio, saved)
        assert audio.restarts == 1 and len(audio.notices) == 1 and audio.notices[0][-4:] == ('omarchy-audio-watchdog', '--repair', 'stack', '--manual'), 'one notice per lasting outage'
        assert m.outage_due() is None
    # A built-in card the user switched off is announced, never "repaired".
    audio = lost(); audio.cards[0]['active_profile'] = 'off'; saved = state()
    deferred(audio, saved)
    with mock.patch.object(m.time, 'monotonic', return_value=later):
        deferred(audio, saved)
    assert audio.restarts == 0 and len(audio.notices) == 1, 'a disabled card is not a lost graph'
    audio.cards[0]['active_profile'] = 'HiFi'
    audio.no_dsp = False
    m.reconcile(audio, saved)
    assert audio.default == m.MAPPING and audio.probes == [m.MAPPING] and marker(saved) is None
    assert m.outage['since'] is None, 'a present array ends the outage'
    # A short loss (card or audio restart) is never announced.
    audio = lost(); saved = state(); deferred(audio, saved)
    audio.no_dsp = False; m.reconcile(audio, saved)
    with mock.patch.object(m.time, 'monotonic', return_value=later):
        audio.no_dsp = True; deferred(audio, saved)
    assert not audio.notices
    # An audio restart during a loss drops the mapping: no pending notice, so
    # the watcher does not wake early while the array stays missing.
    audio = lost(); saved = state(); deferred(audio, saved)
    assert m.outage_due() is not None
    audio.existing = False; audio.linked = {}; audio.module = None
    deferred(audio, saved)
    assert m.outage_due() is None and not audio.notices
    # A muted mapping is the user's mute; an ignored switch is not a claim.
    audio = lost(); audio.mapping['mute'] = True; saved = state()
    deferred(audio, saved)
    assert audio.default == m.MAPPING and marker(saved) is None
    audio = lost(); audio.ignored = ('usb-mic',); saved = state()
    deferred(audio, saved)
    assert audio.default == m.MAPPING and marker(saved) is None
    # Choosing another real input ends the claim, even after an audio restart
    # removed the mapping; choosing the fallback again is then the user's own.
    for restarted in (False, True):
        audio = lost(); saved = state(); deferred(audio, saved)
        if restarted: audio.existing = False; audio.linked = {}; audio.module = None
        audio.default = 'other-mic'; deferred(audio, saved); audio.default = 'usb-mic'; deferred(audio, saved)
        audio.no_dsp = False; m.reconcile(audio, saved)
        assert audio.default == 'usb-mic' and not audio.probes and marker(saved) is None, restarted
    # Losing the claimed input (unplugged) hands over again, or keeps the claim
    # so the returning array still takes over from the monitor left behind.
    for remaining, expected in (([other], 'other-mic'), ([], 'headphones.monitor')):
        audio = lost(); saved = state(); deferred(audio, saved)
        audio.inputs = [dict(item) for item in remaining]; audio.default = 'headphones.monitor'
        deferred(audio, saved)
        assert audio.default == expected and marker(saved) == (expected if remaining else 'usb-mic')
        audio.no_dsp = False; m.reconcile(audio, saved)
        assert audio.default == m.MAPPING and marker(saved) is None
    # On return, a silent or unsampled mapping leaves the working fallback.
    for signal, error in ((False, 'no signal'), (None, 'Could not sample')):
        audio = lost(); saved = state(); deferred(audio, saved)
        audio.no_dsp = False; audio.carries_signal = signal
        try: m.reconcile(audio, saved)
        except RuntimeError as problem: assert error in str(problem), problem
        else: raise AssertionError('a failed return must be reported')
        assert audio.default == 'usb-mic' and marker(saved) == 'usb-mic', signal
        audio.carries_signal = True; m.reconcile(audio, saved)
        assert audio.default == m.MAPPING and marker(saved) is None, 'a later live mapping is selected again'
    # A muted fallback waits: the array never unmutes capture.
    audio = lost(); saved = state(); deferred(audio, saved)
    audio.inputs[0]['mute'] = True; audio.no_dsp = False
    m.reconcile(audio, saved)
    assert audio.default == 'usb-mic' and not audio.probes and marker(saved) == 'usb-mic'
    audio.inputs[0]['mute'] = False; m.reconcile(audio, saved)
    assert audio.default == m.MAPPING and marker(saved) is None
    # A choice seen during setup drops the claim.
    class Diverging(LostDsp):
        def graph(self):
            if self.default == 'usb-mic' and not self.no_dsp: self.default = 'other-mic'
            return super().graph()
    audio = lost(); audio.__class__ = Diverging; saved = state(); deferred(audio, saved)
    audio.no_dsp = False; m.reconcile(audio, saved)
    assert audio.default == 'other-mic' and marker(saved) is None
    audio.__class__ = LostDsp; audio.default = 'usb-mic'; m.reconcile(audio, saved)
    assert audio.default == 'usb-mic'
    # A choice made while the returning mapping is sampled wins.
    audio = lost(); saved = state(); deferred(audio, saved)
    audio.no_dsp = False; audio.probe_choice = 'other-mic'
    m.reconcile(audio, saved)
    assert audio.default == 'other-mic' and marker(saved) is None
    m.outage.update(since=None, notified=False, repaired=False)
    for selected in (DSP, 'usb-mic', ''):
        for failure in (False, True):
            audio = Audio(default=selected); audio.auto_input = True
            if failure: audio.missing = 'input_FR'
            try: m.reconcile(audio, state())
            except RuntimeError:
                assert failure
            else: assert not failure
            expected = selected if failure or selected == 'usb-mic' else m.MAPPING
            assert audio.default == expected, 'module auto-selection must not steal a source or survive failed links'
    for missing in ('capture_AUX0', 'input_FL', 'input_FR'):
        audio = Audio(); audio.missing = missing
        try: m.reconcile(audio, state())
        except RuntimeError: pass
        else: raise AssertionError('missing port accepted')
        assert audio.default == DSP and not audio.existing
    for existing in (False, True):
        audio = Audio(existing); audio.fail_link = 22
        if existing: audio.linked = {90: (21, 'existing')}
        try: m.reconcile(audio, state())
        except RuntimeError: pass
        else: raise AssertionError('failed link accepted')
        assert audio.default == DSP and audio.existing == existing
        assert audio.linked == ({90: (21, 'existing')} if existing else {}), 'rollback must preserve old links'
    for failure in ('fail_module', 'fail_query', 'fail_graph'):
        audio = Audio(); setattr(audio, failure, True)
        try: m.reconcile(audio, state())
        except RuntimeError: pass
        else: raise AssertionError('live failure suppressed')
        assert audio.default == DSP and not audio.existing
    audio = Audio(); audio.concurrent = True
    m.reconcile(audio, state())
    assert audio.default == 'usb-mic', 'concurrent user selections must win'
    audio = Audio(True, m.MAPPING); audio.linked = {90: (21, 'existing'), 91: (22, 'existing')}
    saved = state(); m.reconcile(audio, saved)
    audio.existing = False; audio.linked = {}; audio.module = None; audio.default = DSP
    m.reconcile(audio, saved)
    assert m.gain(audio.mapping) == {'volume': [27525, 27525], 'mute': True}, 'restart must recover owned mapped gain'
    bad = state(); bad.write_text('{invalid')
    audio = Audio()
    try: m.reconcile(audio, bad)
    except ValueError: pass
    else: raise AssertionError('corrupt saved state accepted')
    assert not audio.existing and audio.default == DSP
    runtime = directory / 'runtime'; runtime.mkdir()
    with mock.patch.dict(os.environ, {}, clear=True):
        try: m.run_once(Audio(), runtime, state())
        except m.Deferred: pass
        else: raise AssertionError('absent session was not explicitly deferred')
        (runtime / 'pipewire-0').touch()
        audio = Audio(); audio.fail_query = True
        try: m.run_once(audio, runtime, state())
        except RuntimeError: pass
        else: raise AssertionError('broken live session was deferred')
    entered = threading.Event()
    def concurrent():
        with m.mapping_lock(runtime): entered.set()
    with m.mapping_lock(runtime):
        thread = threading.Thread(target=concurrent); thread.start()
        assert not entered.wait(0.1), 'mapping operations must serialize'
    thread.join(2); assert entered.is_set()
    audio = Audio(True); audio.linked = {90: (21, 'existing'), 91: (22, 'existing')}; saved = state()
    passes = [0]
    def operation():
        passes[0] += 1
        if passes[0] == 2: audio.existing = False; audio.linked = {}; audio.module = None; audio.default = DSP
        if passes[0] == 3: raise KeyboardInterrupt()
        m.reconcile(audio, saved)
    with mock.patch.object(m.time, 'sleep'):
        try: m.supervise(operation, wait=lambda: None)
        except KeyboardInterrupt: pass
    assert audio.existing and len(audio.linked) == 2 and m.gain(audio.mapping)['mute'], 'supervisor must rebuild lost nodes and gain'
    audio = Audio(); saved = state(); passes = [0]
    def retry_operation():
        passes[0] += 1
        if passes[0] == 3: raise KeyboardInterrupt()
        audio.fail_module = passes[0] == 1
        m.reconcile(audio, saved)
    with mock.patch.object(m.time, 'sleep'):
        try: m.supervise(retry_operation, wait=lambda: None)
        except KeyboardInterrupt: pass
    assert audio.existing and len(audio.linked) == 2, 'supervisor must retry a failed live repair'
    # The watcher sleeps on pactl events instead of polling: device events wake
    # it once they settle, application and stream events never do, a steady
    # stream cannot starve repair, and a lost subscription still yields one.
    def feed(script):
        return m.Subscription(command=['bash', '-c', script], quiet=0.1, settle=1.0, backstop=0.6, retry=0.05)
    def timed(sub):
        start = time.monotonic(); sub.wait(); elapsed = time.monotonic() - start; sub.stop(); return elapsed
    elapsed = timed(feed("echo \"Event 'new' on source #7\"; sleep 3"))
    assert 0.1 <= elapsed < 0.6, ('device event must wake after the quiet interval', elapsed)
    elapsed = timed(feed("echo \"Event 'change' on server #0\"; sleep 3"))
    assert 0.1 <= elapsed < 0.6, ('a default device switch must wake the watcher', elapsed)
    elapsed = timed(feed("echo \"Event 'new' on client #9\"; echo \"Event 'change' on sink-input #4\"; echo \"Event 'change' on sink #1\"; echo \"Event 'change' on source #1\"; sleep 3"))
    assert elapsed >= 0.6, ('stream start and stop must not wake before the backstop', elapsed)
    # A change of the mapping's own source (gain, mute) wakes a save-only
    # pass, so an audio restart never restores an older unmuted state; other
    # sources' changes still wake nothing, and a device event still repairs.
    m.mapping_index['value'] = '5'
    sub = feed("echo \"Event 'change' on source #5\"; sleep 3"); start = time.monotonic(); result = sub.wait(); elapsed = time.monotonic() - start; sub.stop()
    assert result is True and 0.1 <= elapsed < 0.6, (result, elapsed)
    sub = feed("echo \"Event 'change' on source #51\"; sleep 3"); result = sub.wait(); sub.stop()
    assert result is False, 'another source changing is not the mapping'
    sub = feed("echo \"Event 'change' on source #5\"; echo \"Event 'new' on sink #1\"; sleep 3"); result = sub.wait(); sub.stop()
    assert result is False, 'a device event with it is a full repair'
    # Save-only wakes never push the backstop out: a microphone in constant
    # use still gets its full repair pass on time.
    sub = feed("while true; do echo \"Event 'change' on source #5\"; sleep 0.15; done")
    results = []; start = time.monotonic()
    while time.monotonic() - start < 1.5:
        results.append(sub.wait())
        if results[-1] is False: break
    sub.stop()
    assert results[-1] is False and True in results[:-1] and time.monotonic() - start < 1.2, results
    m.mapping_index['value'] = None
    saves = []
    def saving(save=False):
        saves.append(save)
        if len(saves) == 3: raise KeyboardInterrupt()
    answers = iter([True, False])
    try: m.supervise(saving, wait=lambda: next(answers))
    except KeyboardInterrupt: pass
    assert saves == [False, True, False], saves
    elapsed = timed(feed("for i in $(seq 20); do echo \"Event 'new' on sink #1\"; sleep 0.05; done; sleep 3"))
    assert 0.9 <= elapsed < 1.5, ('a steady event stream must repair at the settle cap', elapsed)
    sub = feed("sleep 3"); start = time.monotonic(); sub.wait(0.2); elapsed = time.monotonic() - start; sub.stop()
    assert 0.2 <= elapsed < 0.5, ('a pending lost-array notice shortens the wait', elapsed)
    sub = feed('exit 0'); elapsed = timed(sub)
    assert elapsed < 0.5 and sub.process is None, 'a lost subscription must yield a repair and resubscribe later'
    assert timed(m.Subscription(command=['/nonexistent/pactl'], retry=0.05)) < 0.5, 'a missing subscriber must degrade to a paced retry'
# The live probe reads float samples from the mapping through parec: any
# non-zero sample, however quiet, is signal; zeros (either sign) are digital
# silence; a recorder that yields nothing is unknown.
with tempfile.TemporaryDirectory() as temporary:
    fake = Path(temporary) / 'parec'
    def probe(script, timeout=1.0):
        fake.write_text('#!/bin/bash\n' + script + '\n'); fake.chmod(0o755)
        with mock.patch.dict(os.environ, {'PATH': temporary + os.pathsep + os.environ['PATH']}):
            start = time.monotonic(); result = m.Audio().signal(m.MAPPING, timeout); return result, time.monotonic() - start
    floats = 'python3 -c "import struct, sys; sys.stdout.buffer.write(struct.pack(\'<%df\' % {0}, *{1}))"; sleep 5'
    result, elapsed = probe('[[ $1 == --device=omarchy_asahi_mic && $* == *--format=float32le* ]] || exit 1; ' + floats.format(2049, '[0.0] * 2048 + [1e-7]'))
    assert result is True and elapsed < 0.9, ('a quiet non-zero sample is signal', elapsed)
    result, elapsed = probe(floats.format(8192, '[0.0, -0.0] * 4096'))
    assert result is False and 0.9 <= elapsed < 2.5, ('digital silence is not signal', elapsed)
    result, elapsed = probe('exit 1')
    assert result is None and elapsed < 0.9, 'a recorder that yields nothing is unknown'
    with mock.patch.dict(os.environ, {'PATH': str(Path(temporary) / 'missing')}):
        assert m.Audio().signal(m.MAPPING, 1.0) is None, 'a missing recorder is unknown'
with mock.patch.object(m.Audio, 'run', return_value='536870912\tmodule-null-sink\tsink_name=omarchy_asahi_mic omarchy.asahi-mic.owner=test\t1'):
    assert m.Audio().modules()[0]['index'] == '536870912'
listing = '536870911\tlibpipewire-module-rt\t{\n            nice.level    = -11\n        }\t\n536870912\tmodule-null-sink\tsink_name=omarchy_asahi_mic\t1'
with mock.patch.object(m.Audio, 'run', return_value=listing):
    assert [module['index'] for module in m.Audio().modules()] == ['536870911', '536870912'], 'multi-line module arguments must not break rollback'
# Apps show the mapping by its family name, as macOS does: the MacBook's name on
# a MacBook, "Built-in" on any other Mac, never a board code. The name is one
# quoted value inside sink_properties, with the ownership marker still there.
with tempfile.TemporaryDirectory() as temporary:
    for model, name in (('Apple MacBook Pro (14-inch, M1 Pro, 2021)\0', 'MacBook Microphone'),
                        ('Apple MacBook Air (13-inch, M2, 2022)\0', 'MacBook Microphone'),
                        ('Apple iMac (24-inch, 4x USB-C, M1, 2021)\0', 'Built-in Microphone'),
                        (None, 'Built-in Microphone')):
        path = Path(temporary) / 'model'
        path.unlink(missing_ok=True)
        if model is not None: path.write_text(model)
        with mock.patch.object(m, 'MODEL', path):
            audio = Audio()
            m.reconcile(audio, Path(temporary) / 'state.json')
        load = next(call for call in audio.calls if call[:2] == ('pactl', 'load-module'))
        properties = next(arg for arg in load if arg.startswith('sink_properties='))
        assert properties.startswith("sink_properties='device.description=\"" + name + "\" ") and properties.endswith("'"), properties
        assert 'AsahiMicrophone' not in properties and m.OWNER + '=' in properties
        assert m.owned(audio.module, 'Audio/Source/Virtual'), 'the quoted name must not hide the mapping from its owner'
# WirePlumber's stale hidden ids (#1028, seen after a re-login) make pw-link
# fail with EPERM: the mapper restarts WirePlumber so the next event relinks,
# at most once per interval however often the links keep failing. Other link
# failures never restart it.
with tempfile.TemporaryDirectory() as temporary:
    stamp = Path(temporary) / 'run/omarchy-asahi-mic.repaired'
    refused = 'pw-link -L: failed to link ports: Operation not permitted'
    for attempt in range(3):
        audio = Audio(); audio.stamp = stamp; audio.fail_link = 21; audio.link_error = refused
        try: m.reconcile(audio, Path(temporary) / 'state.json')
        except RuntimeError as error: assert 'Operation not permitted' in str(error)
        else: raise AssertionError('a refused link must fail the mapping')
        assert audio.restarts == (1 if attempt == 0 else 0), (attempt, audio.restarts)
        assert not audio.linked, 'a refused mapping is rolled back'
    assert m.recheck['at'] is not None; m.recheck['at'] = None
    stamp.write_text(repr(time.monotonic() - m.REPAIR_INTERVAL - 1))
    audio = Audio(); audio.stamp = stamp; audio.fail_link = 21; audio.link_error = refused
    try: m.reconcile(audio, Path(temporary) / 'state.json')
    except RuntimeError: pass
    assert audio.restarts == 1, 'the repair is allowed again after its interval'
    audio = Audio(); audio.stamp = Path(temporary) / 'other'; audio.fail_link = 21
    try: m.reconcile(audio, Path(temporary) / 'state.json')
    except RuntimeError: pass
    assert audio.restarts == 0, 'other link failures never restart WirePlumber'
# pw-link's EPERM is recognised in English whatever the session's language.
with mock.patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')) as run, \
        mock.patch.dict(os.environ, {'LC_ALL': 'de_DE.UTF-8', 'LANG': 'de_DE.UTF-8'}):
    m.Audio().run('pw-link', '-L', '1', '2')
    assert run.call_args.kwargs['env']['LC_ALL'] == 'C' and run.call_args.kwargs['env']['LANG'] == 'de_DE.UTF-8'
# A restart that cannot run leaves the refused-link error as the mapping's.
with tempfile.TemporaryDirectory() as temporary:
    class Unrestartable(Audio):
        def restart_session_manager(self, reason): raise subprocess.CalledProcessError(1, 'systemctl')
    m.recheck["at"] = None
    audio = Unrestartable(); audio.stamp = Path(temporary) / 'stamp'; audio.fail_link = 21
    audio.link_error = 'pw-link -L: failed to link ports: Operation not permitted'
    try: m.reconcile(audio, Path(temporary) / 'state.json')
    except RuntimeError as error: assert 'Operation not permitted' in str(error), error
    else: raise AssertionError('a refused link must fail the mapping')
    assert m.recheck['at'] is None, 'no re-check follows a restart that did not happen'
# The watchdog owns the restart: the mapper asks it, in a unit of its own so
# the shell is never left stopped by a mapper that stops waiting. A restart
# it defers (a logout, the lock screen, another repair) costs no attempt and
# is asked for again half a minute later; one it refuses or fails does.
with tempfile.TemporaryDirectory() as temporary:
    class Declined(Audio):
        code = 75
        def restart_session_manager(self, reason): self.restarts += 1; return self.code
    stamp = Path(temporary) / 'stamp'
    audio = Declined(); audio.stamp = stamp; audio.fail_link = 21
    audio.link_error = 'pw-link -L: failed to link ports: Operation not permitted'
    try: m.reconcile(audio, Path(temporary) / 'state.json')
    except RuntimeError: pass
    assert audio.restarts == 1 and m.recheck['at'] is None and not stamp.exists(), 'a deferred restart costs nothing'
    audio.code = 76
    try: m.reconcile(audio, Path(temporary) / 'state.json')
    except RuntimeError: pass
    assert audio.restarts == 2 and m.recheck['at'] is None and stamp.exists(), 'a refused restart waits out the interval'
    m.outage.update(since=None, notified=False, repaired=False)
    audio = Declined(); audio.stamp = Path(temporary) / 'outage'; audio.existing = True; audio.no_dsp = True
    with mock.patch.object(m.time, 'monotonic', return_value=5000.0):
        try: m.reconcile(audio, Path(temporary) / 'state.json')
        except m.Deferred: pass
    with mock.patch.object(m.time, 'monotonic', return_value=5000.0 + m.OUTAGE_GRACE):
        try: m.reconcile(audio, Path(temporary) / 'state.json')
        except m.Deferred: pass
        assert audio.restarts == 1 and not audio.notices and not m.outage['notified'], 'a deferred repair is no reason to give up'
        assert 29 <= m.outage_due() <= 30, m.outage_due()
    m.outage.update(since=None, notified=False, repaired=False)
for code in (0, 75, 76, 1):
    with mock.patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], code, b'', b'')) as call:
        assert m.Audio().restart_session_manager('links refused') == code
        args = call.call_args.args[0]
        assert args[:3] == ['systemd-run', '--user', '--wait'] and '--unit=omarchy-audio-repair-%d' % os.getpid() in args, args
        assert args[-5:] == ['omarchy-audio-watchdog', '--repair', 'wireplumber', '--reason', 'links refused'], args
unit = (root / 'vendor/systemd/user/omarchy-asahi-mic.service').read_text()
assert '--watch' in unit and 'PartOf=graphical-session.target' in unit
assert 'PartOf=pipewire.service' not in unit and 'After=graphical-session.target' not in unit
print('ok - transactional Asahi mapping preserves choices/gain, rolls back failures and recovers lifecycle loss')
PY
