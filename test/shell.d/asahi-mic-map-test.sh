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
loader = importlib.machinery.SourceFileLoader('mic', str(root / 'bin/omarchy-audio-asahi-mic-map'))
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
DSP = 'effect_output.j414-mic'
LEGACY = m.LEGACY_MONITOR
def obj(name, value=27525, mute=True):
    return dict(name=name, volume={'front-left': {'value': value}, 'front-right': {'value': value}}, mute=mute)
def metadata(name):
    text = 'Found "default" metadata 126'
    if name is not None:
        text += "\nupdate: id:0 key:'default.configured.audio.source' value:'{ \"name\": \"%s\" }' type:'Spa:String:JSON'" % name
    return text
class Audio:
    # The mapping is a virtual source: it appears among the sources, never the
    # sinks. `legacy` stands in for the null-sink mapping of earlier versions.
    # `configured` is what WirePlumber remembers as the chosen input (None when
    # the default is only its own pick); pactl set-default-source writes it.
    def __init__(self, existing=False, default=DSP, legacy=False, configured=None):
        self.calls = []; self.default = default; self.existing = existing; self.legacy = legacy; self.configured = configured
        self.source = obj(m.MAPPING); self.legacy_sink = obj(m.MAPPING, 32768, False); self.legacy_monitor = obj(LEGACY, 65536, True)
        self.module = None
        self.legacy_module = dict(index='41', name='module-null-sink', argument='sink_name=' + m.MAPPING + ' channels=2 sink_properties=device.description=AsahiMicrophone node.virtual=true ' + m.OWNER + '=old') if legacy else None
        self.linked = {}; self.missing = None; self.fail_link = None; self.fail_module = False
        self.fail_query = False; self.fail_graph = False; self.concurrent = False
        self.next_id = 100; self.auto_input = False; self.initial_input = default; self.no_dsp = False
    def objects(self, kind):
        if self.fail_query: raise RuntimeError('live Pulse query failed')
        if kind == 'sources':
            return (([] if self.no_dsp else [obj(DSP)]) + [obj('usb-mic')] + ([copy.deepcopy(self.source)] if self.existing else [])
                    + ([copy.deepcopy(self.legacy_monitor)] if self.legacy else []))
        if kind == 'sinks': return [obj('speakers')] + ([copy.deepcopy(self.legacy_sink)] if self.legacy else [])
        raise AssertionError(kind)
    def modules(self): return [module for module in (self.legacy_module, self.module) if module]
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
    def run(self, *args):
        self.calls.append(args)
        if args[0] == 'pw-link':
            if args[1] == '-d': self.linked.pop(int(args[2])); return ''
            input_ = int(args[-1]); self.next_id += 1
            self.linked[self.next_id] = (input_, json.loads(args[4])[m.OWNER])
            if self.fail_link == input_: raise RuntimeError('link rejected after partial creation')
            return ''
        if args[0] == 'pw-metadata': return metadata(self.configured)
        assert args[0] == 'pactl', args
        command = args[1]
        if command == 'get-default-source': return self.default
        if command == 'get-default-sink': return 'speakers'
        if command == 'load-module':
            if self.fail_module: raise RuntimeError('module failed')
            assert 'media.class=' + m.MEDIA_CLASS in args, 'the mapping must be a virtual source'
            self.module = dict(index='42', name='module-null-sink', argument=' '.join(args[2:]))
            self.existing = True
            if self.auto_input: self.default = m.MAPPING
            self.source = obj(m.MAPPING, 65536, False)
            return '42'
        if command == 'unload-module':
            if args[2] == '41':
                self.legacy = False; self.legacy_module = None
                if self.default == LEGACY: self.default = DSP
            else:
                self.existing = False; self.module = None; self.linked = {}
                if self.default == m.MAPPING: self.default = self.initial_input
            return ''
        if command == 'set-default-source': self.default = args[2]; self.configured = args[2]; return ''
        assert args[2] == m.MAPPING, 'DSP/user device must never be modified'
        if command == 'set-source-volume':
            self.source['volume'] = {str(i): {'value': int(value)} for i, value in enumerate(args[3:])}; return ''
        if command == 'set-source-mute': self.source['mute'] = args[3] == '1'; return ''
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
    # Simulate a choice made during the final graph query. The last
    # default-source read must observe that new choice.
    class FinalQueryChoice(Audio):
        def __init__(self):
            super().__init__()
            self.choice_injected = False
        def graph(self):
            graph = super().graph()
            if len(self.linked) == 2 and not self.choice_injected:
                self.default = 'usb-mic'
                self.choice_injected = True
            return graph
    audio = FinalQueryChoice()
    m.reconcile(audio, state())
    assert audio.choice_injected and audio.default == 'usb-mic'
    assert ('pactl', 'set-default-source', m.MAPPING) not in audio.calls
    for selected in (DSP, 'usb-mic', m.MAPPING):
        audio = Audio(True, selected); audio.linked = {90: (21, 'existing'), 91: (22, 'existing')}
        before = copy.deepcopy(audio.source); saved = state()
        m.reconcile(audio, saved); m.reconcile(audio, saved)
        assert audio.source == before, '42 percent and mute must survive repeat mapping'
        assert not any('volume' in call[1] or 'mute' in call[1] for call in audio.calls)
        assert audio.default == (m.MAPPING if selected == DSP else selected)
        assert sum(call[1] == 'set-default-source' for call in audio.calls) == (1 if selected == DSP else 0)
    # A DSP the user chose on purpose (the audio panel writes the configured
    # default) is not taken over; one WirePlumber merely picked by priority is.
    for configured, expected in ((DSP, DSP), (None, m.MAPPING), ('usb-mic', m.MAPPING)):
        audio = Audio(True, DSP, configured=configured); audio.linked = {90: (21, 'existing'), 91: (22, 'existing')}
        m.reconcile(audio, state()); m.reconcile(audio, state())
        assert audio.default == expected, ('configured input must decide the takeover', configured, audio.default)
    audio = Audio(default='usb-mic'); audio.no_dsp = True
    try: m.reconcile(audio, state())
    except m.Deferred: pass
    else: raise AssertionError('Apple desktop without a mic array should defer safely')
    assert not audio.calls and audio.default == 'usb-mic'
    for selected in (DSP, 'usb-mic', ''):
        for failure in (False, True):
            audio = Audio(default=selected); audio.auto_input = True
            if failure: audio.missing = 'input_FR'
            try: m.reconcile(audio, state())
            except RuntimeError:
                assert failure
            else: assert not failure
            expected = selected if failure or selected == 'usb-mic' else m.MAPPING
            assert audio.default == expected, ('module auto-selection must not steal a source or survive failed links', selected, failure, audio.default)
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
    assert json.loads(saved.read_text()) == {'source': {'volume': [27525, 27525], 'mute': True}}
    audio.existing = False; audio.linked = {}; audio.default = DSP
    m.reconcile(audio, saved)
    assert m.gain(audio.source) == {'volume': [27525, 27525], 'mute': True}, 'restart must recover owned mapped gain'
    assert audio.default == m.MAPPING, 'a mapping WirePlumber lost is selected again'
    # The null-sink mapping of earlier versions is replaced, keeping the gain
    # apps heard (sink times monitor) and its place as the default input.
    for selected in (LEGACY, 'usb-mic'):
        audio = Audio(legacy=True, default=selected); saved = state()
        m.reconcile(audio, saved)
        assert not audio.legacy and audio.existing and len(audio.linked) == 2
        assert ('pactl', 'unload-module', '41') in audio.calls
        assert audio.default == (m.MAPPING if selected == LEGACY else selected)
        assert m.gain(audio.source) == {'volume': [32768, 32768], 'mute': True}, 'legacy gain must carry over as the product'
        assert json.loads(saved.read_text()) == {'source': {'volume': [32768, 32768], 'mute': True}}
    audio = Audio(legacy=True); audio.legacy_module['argument'] = 'sink_name=' + m.MAPPING + ' channels=2'
    try: m.reconcile(audio, state())
    except RuntimeError as error: assert 'does not own' in str(error)
    else: raise AssertionError('a foreign sink of the same name was replaced')
    assert audio.legacy and not audio.existing
    # A saved legacy state (sink and monitor gain) restores as their product.
    legacy_state = state(); legacy_state.write_text(json.dumps(dict(sink=dict(volume=[32768, 32768], mute=False), monitor=dict(volume=[65536, 65536], mute=True))))
    audio = Audio(); m.reconcile(audio, legacy_state)
    assert m.gain(audio.source) == {'volume': [32768, 32768], 'mute': True}
    assert json.loads(legacy_state.read_text()) == {'source': {'volume': [32768, 32768], 'mute': True}}
    # Unreadable state is a lost gain, not a lost microphone: the mapping is
    # still created and the file replaced by a readable one.
    for bad_text in ('{invalid', json.dumps(dict(sink=dict(volume=[1, 1], mute=False))), '[]'):
        bad = state(); bad.write_text(bad_text)
        audio = Audio(); m.reconcile(audio, bad)
        assert audio.existing and audio.default == m.MAPPING, ('unreadable state must not block the mapping', bad_text)
        assert json.loads(bad.read_text()) == {'source': {'volume': [65536, 65536], 'mute': False}}
    # One transient failure must not demote the mapping for good: the mapper's
    # own default writes are not the user's choice. A: legacy monitor selected,
    # the new mapping's ports are late once. B: the mapping was the configured
    # input, WirePlumber fell back to the DSP while it was gone and re-selects
    # it when it reappears; links fail once. C: as B, but a USB mic had the
    # fallback. Every retry must end on the mapping with the choice intact.
    audio = Audio(legacy=True, default=LEGACY, configured=LEGACY); audio.missing = 'input_FR'
    try: m.reconcile(audio, state())
    except RuntimeError: pass
    else: raise AssertionError('late port accepted')
    assert not audio.legacy and not audio.existing and audio.default == DSP
    audio.missing = None; m.reconcile(audio, state())
    assert audio.existing and audio.default == m.MAPPING, 'a retried migration must still take over'
    for fallback in (DSP, 'usb-mic'):
        audio = Audio(default=fallback, configured=m.MAPPING); audio.auto_input = True; audio.fail_link = 22
        try: m.reconcile(audio, state())
        except RuntimeError: pass
        else: raise AssertionError('failed link accepted')
        assert not audio.existing and audio.default == fallback and audio.configured == m.MAPPING, 'rollback must not rewrite the configured input'
        audio.fail_link = None; m.reconcile(audio, state())
        assert audio.existing and audio.default == m.MAPPING and audio.configured == m.MAPPING, ('a configured mapping is restored after a retry', fallback)
    # A legacy sink whose monitor is already gone still retires, and the gain
    # comes from the old-format state file.
    audio = Audio(legacy=True, default='usb-mic'); audio.legacy_monitor = obj('unrelated.monitor')
    legacy_state = state(); legacy_state.write_text(json.dumps(dict(sink=dict(volume=[16384, 16384], mute=False), monitor=dict(volume=[65536, 65536], mute=False))))
    m.reconcile(audio, legacy_state)
    assert not audio.legacy and audio.existing and audio.default == 'usb-mic'
    assert m.gain(audio.source) == {'volume': [16384, 16384], 'mute': False}
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
        if passes[0] == 2: audio.existing = False; audio.linked = {}; audio.default = DSP
        if passes[0] == 3: raise KeyboardInterrupt()
        m.reconcile(audio, saved)
    with mock.patch.object(m.time, 'sleep'):
        try: m.supervise(operation, wait=lambda: None)
        except KeyboardInterrupt: pass
    assert audio.existing and len(audio.linked) == 2 and m.gain(audio.source)['mute'], 'supervisor must rebuild lost nodes and gain'
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
    elapsed = timed(feed("for i in $(seq 20); do echo \"Event 'new' on sink #1\"; sleep 0.05; done; sleep 3"))
    assert 0.9 <= elapsed < 1.5, ('a steady event stream must repair at the settle cap', elapsed)
    sub = feed('exit 0'); elapsed = timed(sub)
    assert elapsed < 0.5 and sub.process is None, 'a lost subscription must yield a repair and resubscribe later'
    assert timed(m.Subscription(command=['/nonexistent/pactl'], retry=0.05)) < 0.5, 'a missing subscriber must degrade to a paced retry'
    stub = directory / 'bin'; stub.mkdir()
    for name, body in [('omarchy-hw-apple', 'exit 0'), ('systemctl', 'echo "$*" >> "$CALLS"'), ('omarchy-audio-asahi-mic-map', 'echo live-diagnostic >&2; exit "$MAP_STATUS"')]:
        path = stub / name; path.write_text('#!/bin/bash\n' + body + '\n'); path.chmod(0o755)
    home = directory / 'home'; home.mkdir()
    policy = home / '.config/wireplumber/wireplumber.conf.d/asahi-headset-mic.conf'; policy.parent.mkdir(parents=True)
    calls = directory / 'calls'
    env = dict(os.environ, HOME=str(home), OMARCHY_PATH=str(root), PATH=str(stub) + ':' + os.environ['PATH'], XDG_RUNTIME_DIR=str(directory / 'no-session'), CALLS=str(calls))
    command = ['bash', '-euo', 'pipefail', '-c', 'source "$OMARCHY_PATH/install/user/hardware/apple/mic.sh"']
    for contents in (None, 'custom policy'):
        if contents: policy.write_text(contents)
        result = subprocess.run(command, env=dict(env, MAP_STATUS='75'), capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        if contents: assert policy.read_text() == contents
    policy.unlink(); policy.symlink_to(directory / 'missing-custom-target')
    result = subprocess.run(command, env=dict(env, MAP_STATUS='1'), capture_output=True, text=True)
    assert result.returncode == 1 and 'live-diagnostic' in result.stderr and policy.is_symlink()
    result = subprocess.run(['bash', '-euo', 'pipefail', str(root / 'migrations/1788979860.sh')], env=dict(env, MAP_STATUS='1'), capture_output=True, text=True)
    assert result.returncode == 1 and 'live-diagnostic' in result.stderr, 'migration must remain failed on a live mapper error'
    assert not calls.exists(), 'offline provisioning must not contact the user manager'
    assert (home / '.config/systemd/user/graphical-session.target.wants/omarchy-asahi-mic.service').is_symlink()
    assert (home / '.config/systemd/user/omarchy-asahi-mic.service').exists()
# asahi-audio's module-rt argument spans lines; continuation lines are not modules.
with mock.patch.object(m.Audio, 'run', return_value='536870912\tmodule-null-sink\tsink_name=omarchy_asahi_mic omarchy.asahi-mic.owner=test\t1\n\tnice.level = -11\n536870913\tmodule-rt\tnice.level=-11\t'):
    modules = m.Audio().modules()
    assert [module['index'] for module in modules] == ['536870912', '536870913']
with mock.patch.object(m.Audio, 'run', return_value=metadata('usb-mic')):
    assert m.configured_source(m.Audio()) == 'usb-mic'
with mock.patch.object(m.Audio, 'run', return_value=metadata(None)):
    assert m.configured_source(m.Audio()) == ''
unit = (root / 'default/systemd/user/omarchy-asahi-mic.service').read_text()
assert '--watch' in unit and 'PartOf=graphical-session.target' in unit
assert 'PartOf=pipewire.service' not in unit and 'After=graphical-session.target' not in unit
autostart = (root / 'default/hypr/autostart.lua').read_text()
assert 'systemctl --user is-enabled --quiet omarchy-asahi-mic.service && systemctl --user start omarchy-asahi-mic.service' in autostart, 'a disabled mapper must stay disabled across logins'
assert '--save-state' in (root / 'bin/omarchy-restart-audio').read_text()
assert 'mic.sh' in (root / 'migrations/1788979860.sh').read_text()
print('ok - transactional Asahi mapping is a virtual source, preserves choices/gain, retires the null sink, rolls back failures and recovers lifecycle loss')
PY
