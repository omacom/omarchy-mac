#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
python3 - "$ROOT" <<'PY'
import copy
import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import tempfile
from unittest import mock
root = Path(sys.argv[1])
loader = importlib.machinery.SourceFileLoader('mic', str(root / 'bin/omarchy-audio-asahi-mic-map'))
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
RAW = 'alsa_input.changed-after-reboot'
DSP = 'effect_output.j456-mic'
def node(id_, **props):
    return dict(id=id_, type='PipeWire:Interface:Node', info=dict(props=props))
class Audio:
    def __init__(self, default=RAW):
        self.default = default
        self.serial = 99
        self.identity = 'AppleJ456HPAI'
        self.channels = ['AUX0', 'AUX1', 'AUX2']
        self.fallback = None
        self.connected = True
        self.concurrent = False
        self.auto_select = False
        self.calls = []
        self.mute = False
        self.volume = 65536
    def active(self):
        return self.fallback.process is not None and self.fallback.process.poll() is None
    def graph(self):
        graph = [node(1, **{'node.name': RAW, 'media.class': 'Audio/Source', 'alsa.id': self.identity,
                           'audio.channels': len(self.channels), 'object.serial': self.serial,
                           'api.alsa.pcm.stream': 'capture', 'alsa.driver_name': 'snd_soc_aop'})]
        for i, channel in enumerate(self.channels):
            graph.append(dict(id=10+i, type='PipeWire:Interface:Port', info=dict(props={
                'node.id': 1, 'audio.channel': channel, 'port.direction': 'out', 'port.name': 'capture_' + channel})))
        if self.active():
            graph.append(node(2, **{'node.name': m.J456_CAPTURE}))
            graph.append(dict(id=22, type='PipeWire:Interface:Port', info=dict(props={
                'node.id': 2, 'port.name': 'input_AUX2'})))
            if self.connected:
                graph.append(dict(id=30, type='PipeWire:Interface:Link', info={
                    'output-port-id': 12, 'input-node-id': 2, 'input-port-id': 22, 'state': 'paused'}))
            if self.concurrent:
                self.default = 'usb-mic'
        return graph
    def objects(self, kind):
        assert kind == 'sources'
        sources = [dict(name=name) for name in [RAW, 'usb-mic', DSP]]
        if self.active():
            sources.append(dict(name=m.J456_SOURCE, volume={'mono': {'value': self.volume}}, mute=self.mute))
        return sources
    def pause(self): pass
    def run(self, *args):
        self.calls.append(args)
        assert args[0] == 'pactl'
        if args[1] == 'get-default-source': return self.default
        if args[1] == 'set-default-source': self.default = args[2]; return ''
        assert args[2] == m.J456_SOURCE, 'must never alter physical/external gain'
        if args[1] == 'set-source-volume': self.volume = int(args[3]); return ''
        if args[1] == 'set-source-mute': self.mute = args[3] == '1'; return ''
        raise AssertionError(args)
class Child:
    def __init__(self): self.dead = False
    def poll(self): return 0 if self.dead else None
    def terminate(self): self.dead = True
    def wait(self, **kwargs): return 0
with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    count = 0
    def setup(default=RAW):
        global count
        count += 1
        audio = Audio(default)
        fallback = m.J456Fallback(directory, directory / ('state-' + str(count)))
        audio.fallback = fallback
        children = []
        def launch(serial):
            child = Child(); children.append(child)
            fallback.process = child; fallback.target = serial
            if audio.auto_select: audio.default = m.J456_SOURCE
        fallback.start = launch
        return audio, fallback, children
    def reconcile(audio, fallback, dsp=None):
        return fallback.reconcile(audio, audio.objects('sources'), dsp)
    for identity in ('AppleJ314', 'AppleJ456', 'AppleJ457HPAI', None):
        audio, fallback, children = setup(); audio.identity = identity
        assert not reconcile(audio, fallback) and not children
    for channels in ([], ['MONO'], ['AUX0', 'AUX1'], ['AUX0', 'AUX1', 'AUX3']):
        audio, fallback, children = setup(); audio.channels = channels
        assert not reconcile(audio, fallback) and not children
    audio, fallback, children = setup()
    duplicate = audio.graph() + [node(3, **audio.graph()[0]['info']['props'])]
    # A duplicate capture with the required ports is ambiguous and must defer.
    duplicate += [dict(id=40+i, type='PipeWire:Interface:Port', info=dict(props={
        'node.id': 3, 'audio.channel': c, 'port.direction': 'out'})) for i,c in enumerate(audio.channels)]
    assert m.j456_raw(duplicate) is None
    for selected in (RAW, 'usb-mic', 'imac_microphone'):
        for auto in (False, True):
            audio, fallback, children = setup(selected)
            # Existing custom source represents the user's already working setup.
            objects = audio.objects
            audio.objects = lambda kind: objects(kind) + [dict(name='imac_microphone')]
            audio.auto_select = auto
            assert reconcile(audio, fallback)
            assert audio.default == (m.J456_SOURCE if selected == RAW else selected)
            audio.mute = True; audio.volume = 27525
            assert reconcile(audio, fallback) and len(children) == 1
            assert audio.mute and audio.volume == 27525
            # Daemon loss kills the child; the next event rebuilds with saved gain.
            children[-1].dead = True
            audio.default = RAW if selected == RAW else selected
            audio.mute = False; audio.volume = 65536
            assert reconcile(audio, fallback) and len(children) == 2
            assert audio.mute and audio.volume == 27525
            assert audio.default == (m.J456_SOURCE if selected == RAW else selected)
            # A recreated raw node uses its new serial rather than a stale target.
            old = children[-1]; audio.serial = 101
            assert reconcile(audio, fallback) and old.dead and fallback.target == 101
            old = children[-1]
            assert not reconcile(audio, fallback, DSP) and old.dead
            assert audio.default == (DSP if selected == RAW else selected)
    audio, fallback, children = setup(); audio.concurrent = True
    assert reconcile(audio, fallback) and audio.default == 'usb-mic'
    audio, fallback, children = setup(); audio.connected = False
    try: reconcile(audio, fallback)
    except RuntimeError: pass
    else: raise AssertionError('unconnected filter selected')
    assert audio.default == RAW and children[-1].dead
    audio, fallback, children = setup()
    assert not reconcile(audio, fallback, DSP) and not children
    audio, fallback, children = setup()
    sources = audio.objects('sources') + [dict(name=m.J456_SOURCE)]
    try: fallback.reconcile(audio, sources, None)
    except m.Deferred: pass
    else: raise AssertionError('independent source claimed')
    assert not children
    audio, fallback, children = setup()
    reconcile(audio, fallback)
    audio.mute = True; audio.volume = 25000
    audio.identity = 'another-card'
    assert not reconcile(audio, fallback) and children[-1].dead
    audio.identity = 'AppleJ456HPAI'; audio.mute = False; audio.volume = 65536
    assert reconcile(audio, fallback) and audio.mute and audio.volume == 25000
    # Exercise real config generation, cleanup and process ownership without audio.
    fallback = m.J456Fallback(directory, directory / 'gain')
    with mock.patch.dict(m.os.environ, OMARCHY_PATH=str(root)), mock.patch.object(m.subprocess, 'Popen', return_value=Child()) as popen:
        fallback.start(123)
        path = Path(popen.call_args.args[0][-1]); config = path.read_text()
        assert 'target.object = "123"' in config and '@TARGET@' not in config
        assert 'priority.session = 1' in config and 'inputs = [ null null "highpass:In" ]' in config
        child = fallback.process
        fallback.close()
        assert child.dead and not path.exists()
print('ok - J456 identity, channel gates, defaults, DSP handoff, owned child recovery and saved gain')
PY
