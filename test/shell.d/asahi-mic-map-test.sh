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
def obj(name, value=27525, mute=True):
    return dict(name=name, volume={'front-left': {'value': value}, 'front-right': {'value': value}}, mute=mute)
class Audio:
    def __init__(self, existing=False, default=DSP):
        self.calls = []; self.default = default; self.output = 'speakers'; self.existing = existing
        self.sink = obj(m.SINK); self.monitor = obj(m.MONITOR); self.module = None
        self.linked = {}; self.missing = None; self.fail_link = None; self.fail_module = False
        self.fail_query = False; self.fail_graph = False; self.concurrent = False
        self.next_id = 100; self.auto_input = False; self.initial_input = default; self.no_dsp = False
    def objects(self, kind):
        if self.fail_query: raise RuntimeError('live Pulse query failed')
        if kind == 'sources': return ([] if self.no_dsp else [obj(DSP)]) + [obj('usb-mic')] + ([copy.deepcopy(self.monitor)] if self.existing else [])
        if kind == 'sinks': return [obj('speakers')] + ([copy.deepcopy(self.sink)] if self.existing else [])
        if kind == 'modules': return [self.module] if self.module else []
        raise AssertionError(kind)
    def modules(self): return [self.module] if self.module else []
    def graph(self):
        if self.fail_graph: raise RuntimeError('live graph query failed')
        nodes = [dict(id=1, type='PipeWire:Interface:Node', info={'props': {'node.name': DSP}})]
        ports = [(11, 1, 'capture_AUX0')]
        if self.existing:
            nodes.append(dict(id=2, type='PipeWire:Interface:Node', info={'props': {'node.name': m.SINK}}))
            ports += [(21, 2, 'playback_FL'), (22, 2, 'playback_FR')]
        for id_, node, name in ports:
            if name != self.missing: nodes.append(dict(id=id_, type='PipeWire:Interface:Port', info={'props': {'node.id': node, 'port.name': name}}))
        for id_, (input_, owner) in self.linked.items():
            nodes.append(dict(id=id_, type='PipeWire:Interface:Link', info={'output-port-id': 11, 'input-port-id': input_, 'state': 'paused', 'props': {m.OWNER: owner}}))
        if self.concurrent and len(self.linked) == 2: self.default = 'usb-mic'; self.output = 'headphones'
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
        assert args[0] == 'pactl', args
        command = args[1]
        if command == 'get-default-source': return self.default
        if command == 'get-default-sink': return self.output
        if command == 'load-module':
            if self.fail_module: raise RuntimeError('module failed')
            self.module = dict(index=42, name='module-null-sink', argument=' '.join(args[2:]))
            self.existing = True; self.output = m.SINK
            if self.auto_input: self.default = m.MONITOR
            self.sink = obj(m.SINK, 65536, False); self.monitor = obj(m.MONITOR, 65536, False)
            return '42'
        if command == 'unload-module':
            self.existing = False; self.module = None; self.linked = {}
            if self.default == m.MONITOR: self.default = self.initial_input
            return ''
        if command == 'set-default-source': self.default = args[2]; return ''
        if command == 'set-default-sink': self.output = args[2]; return ''
        target = self.sink if args[2] == m.SINK else self.monitor
        assert args[2] in (m.SINK, m.MONITOR), 'DSP/user device must never be modified'
        if command.endswith('-volume'):
            target['volume'] = {str(i): {'value': int(value)} for i, value in enumerate(args[3:])}; return ''
        if command.endswith('-mute'): target['mute'] = args[3] == '1'; return ''
        raise AssertionError(args)
with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    def state():
        path = directory / ('state-' + str(len(list(directory.iterdir()))) + '.json'); return path
    # Numeric IDs may be recycled while the transaction is running. Old links
    # alone are not proof that the named DSP and stereo ports still own them.
    for missing in ('capture_AUX0', 'playback_FL', 'playback_FR'):
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
        assert ('pactl', 'set-default-source', m.MONITOR) not in audio.calls
    # Simulate a choice made during the final graph query, after output has
    # been restored. The last default-source read must observe that new choice.
    class FinalQueryChoice(Audio):
        def __init__(self):
            super().__init__()
            self.choice_injected = False
        def graph(self):
            graph = super().graph()
            if ('pactl', 'set-default-sink', 'speakers') in self.calls:
                self.default = 'usb-mic'
                self.choice_injected = True
            return graph
    audio = FinalQueryChoice()
    m.reconcile(audio, state())
    assert audio.choice_injected and audio.default == 'usb-mic'
    assert ('pactl', 'set-default-source', m.MONITOR) not in audio.calls
    for selected in (DSP, 'usb-mic', m.MONITOR):
        audio = Audio(True, selected); audio.linked = {90: (21, 'existing'), 91: (22, 'existing')}
        before = copy.deepcopy((audio.sink, audio.monitor)); saved = state()
        m.reconcile(audio, saved); m.reconcile(audio, saved)
        assert (audio.sink, audio.monitor) == before, '42 percent and mute must survive repeat mapping'
        assert not any('volume' in call[1] or 'mute' in call[1] for call in audio.calls)
        assert audio.default == (m.MONITOR if selected == DSP else selected)
        assert sum(call[1] == 'set-default-source' for call in audio.calls) == (1 if selected == DSP else 0)
    audio = Audio(default='usb-mic'); audio.no_dsp = True
    try: m.reconcile(audio, state())
    except m.Deferred: pass
    else: raise AssertionError('Apple desktop without a mic array should defer safely')
    assert not audio.calls[2:] and audio.default == 'usb-mic'
    for selected in (DSP, 'usb-mic', ''):
        for failure in (False, True):
            audio = Audio(default=selected); audio.auto_input = True
            if failure: audio.missing = 'playback_FR'
            try: m.reconcile(audio, state())
            except RuntimeError:
                assert failure
            else: assert not failure
            expected = selected if failure or selected == 'usb-mic' else m.MONITOR
            assert audio.default == expected, 'module auto-selection must not steal a source or survive failed links'
    for missing in ('capture_AUX0', 'playback_FL', 'playback_FR'):
        audio = Audio(); audio.missing = missing
        try: m.reconcile(audio, state())
        except RuntimeError: pass
        else: raise AssertionError('missing port accepted')
        assert audio.default == DSP and not audio.existing and audio.output == 'speakers'
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
    assert audio.default == 'usb-mic' and audio.output == 'headphones', 'concurrent user selections must win'
    audio = Audio(True, m.MONITOR); audio.linked = {90: (21, 'existing'), 91: (22, 'existing')}
    saved = state(); m.reconcile(audio, saved)
    audio.existing = False; audio.linked = {}; audio.default = DSP
    m.reconcile(audio, saved)
    assert m.gain(audio.monitor) == {'volume': [27525, 27525], 'mute': True}, 'restart must recover owned mapped gain'
    assert m.gain(audio.sink) == {'volume': [27525, 27525], 'mute': True}
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
        if passes[0] == 2: audio.existing = False; audio.linked = {}; audio.default = DSP
        if passes[0] == 3: raise KeyboardInterrupt()
        m.reconcile(audio, saved)
    with mock.patch.object(m.time, 'sleep'):
        try: m.supervise(operation, wait=lambda: None)
        except KeyboardInterrupt: pass
    assert audio.existing and len(audio.linked) == 2 and m.gain(audio.monitor)['mute'], 'supervisor must rebuild lost nodes and gain'
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
with mock.patch.object(m.Audio, 'run', return_value='536870912\tmodule-null-sink\tsink_name=omarchy_asahi_mic omarchy.asahi-mic.owner=test\t1'):
    assert m.Audio().modules()[0]['index'] == '536870912'
unit = (root / 'default/systemd/user/omarchy-asahi-mic.service').read_text()
assert '--watch' in unit and 'PartOf=graphical-session.target' in unit
assert 'PartOf=pipewire.service' not in unit and 'After=graphical-session.target' not in unit
assert 'systemctl --user start omarchy-asahi-mic.service' in (root / 'default/hypr/autostart.lua').read_text()
assert '--save-state' in (root / 'bin/omarchy-restart-audio').read_text()
assert 'mic.sh' in (root / 'migrations/1788979860.sh').read_text()
print('ok - transactional Asahi mapping preserves choices/gain, rolls back failures and recovers lifecycle loss')
PY
