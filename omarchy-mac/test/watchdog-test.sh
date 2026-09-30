#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
python3 - "$ROOT" <<'PY'
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest import mock
root = Path(sys.argv[1])
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader('watchdog', str(root / 'bin/omarchy-audio-watchdog'))
spec = importlib.util.spec_from_loader(loader.name, loader)
w = importlib.util.module_from_spec(spec); loader.exec_module(w)
temporary = tempfile.TemporaryDirectory()


class Fake(w.System):
    # The audio stack, logind, the lock screen, the shell and the clocks as
    # the watchdog sees them.
    def __init__(self):
        self.runtime = Path(tempfile.mkdtemp(dir=temporary.name))
        self.ticks = 100
        self.mono = 1000.0; self.boot = 5000.0
        self.active = True; self.unit_state = 'active'; self.healthy = True; self.locked = False
        self.wp = 50; self.wp_start = 10.0; self.wp_cpu = 0.0; self.wp_load = 0.0
        self.shell_running = True; self.shell_stops = True; self.shell_result = True; self.restart_result = True; self.heals = True
        self.shell_starts = 0; self.locks = 0
        self.probes = 0; self.stack_restarts = 0; self.wp_restarts = 0
        self.notices = []; self.order = []
    def boottime(self): return self.boot
    def monotonic(self): return self.mono
    def sleep(self, seconds):
        self.mono += seconds; self.boot += seconds; self.wp_cpu += self.wp_load * seconds
    def session_active(self): return self.active
    def units(self): return self.unit_state
    def lock_state(self): return 'the screen is locked' if self.locked else None
    def lock_screen(self): self.locks += 1
    def main_pid(self, unit): return self.wp if unit == 'wireplumber.service' else None
    def stat(self, pid): return (self.wp_cpu, self.wp_start) if pid == self.wp else None
    def probe(self):
        self.probes += 1
        return self.healthy
    def stop_shell(self):
        self.order.append('stop shell')
        if not self.shell_running: return 'none'
        if not self.shell_stops: return 'failed'
        self.shell_running = False
        return 'stopped'
    def start_shell(self):
        self.order.append('start shell'); self.shell_starts += 1
        if self.shell_result: self.shell_running = True
        return self.shell_result
    def restart_stack(self):
        self.order.append('restart stack'); self.stack_restarts += 1
        if self.heals: self.healthy = True; self.unit_state = 'active'
        return self.restart_result
    def restart_wireplumber(self):
        self.order.append('restart wireplumber'); self.wp_restarts += 1
        if self.heals: self.healthy = True
        return self.restart_result
    def notify(self, headline, body, *command): self.notices.append((headline, command))


def hang(fake):
    fake.healthy = False; fake.heals = False


def run(watch, seconds):
    for _ in range(int(seconds / w.TICK)):
        watch.step(); watch.system.sleep(w.TICK)


# A healthy stack is probed every half minute and never restarted. The first
# half minute after the watcher starts (a login) judges nothing.
fake = Fake(); watch = w.Watch(fake)
run(watch, 25)
assert fake.probes == 0, 'nothing is judged while a session settles'
run(watch, 300)
assert 9 <= fake.probes <= 11 and fake.stack_restarts == 0, fake.probes
print('ok - a healthy stack is probed twice a minute and left alone')

# A hung server (every pactl call times out) is restarted once the failure is
# confirmed five to ten seconds later, and the user is told.
fake = Fake(); watch = w.Watch(fake); run(watch, 60)
fake.healthy = False
run(watch, 30)
assert fake.stack_restarts == 1, fake.stack_restarts
assert fake.order == ['stop shell', 'restart stack', 'start shell'], fake.order
assert fake.notices == [('Audio restarted', ())], fake.notices
assert Path(fake.runtime / 'omarchy-audio-repairs').read_text().split()[1] == 'stack'
run(watch, 25)
assert fake.stack_restarts == 1, 'a restarted stack settles before it is judged again'
print('ok - a hung audio server is restarted around a stopped shell, with a notice')

# Quickshell crashes when audio goes away under it, and a crashed locker
# leaves the session locked for good: nothing restarts while the screen is
# locked or locking. It waits for the unlock.
fake = Fake(); watch = w.Watch(fake); run(watch, 60)
fake.healthy = False; fake.locked = True
run(watch, 600)
assert fake.stack_restarts == 0 and not fake.order and not fake.notices, (fake.order, fake.notices)
fake.locked = False
run(watch, 40)
assert fake.stack_restarts == 1 and fake.notices == [('Audio restarted', ())]
fake = Fake(); fake.shell_running = False
assert w.repair(fake, 'stack', 'test') == 0 and fake.order == ['stop shell', 'restart stack'], 'no shell is started that was not running'
fake = Fake(); fake.shell_stops = False
assert w.repair(fake, 'stack', 'test') == w.DEFERRED and fake.stack_restarts == 0, 'audio never restarts under a shell that would not stop'
assert fake.order == ['stop shell', 'start shell'] and (fake.runtime / 'omarchy-audio-repairs').exists()
fake.boot += 5
assert w.repair(fake, 'stack', 'test') == w.DEFERRED and fake.order == ['stop shell', 'start shell'], 'a failed stop counts: the shell is not killed again at once'
fake = Fake(); fake.stop_shell = lambda: 'unknown'
assert w.repair(fake, 'stack', 'test') == w.DEFERRED and fake.stack_restarts == 0 and not fake.order, 'an unknown shell is not touched'
fake = Fake(); fake.shell_result = False
assert w.repair(fake, 'stack', 'test') == 0 and fake.shell_starts == w.SHELL_STARTS, 'a shell that does not come back is tried again'
fake = Fake()
fake.start_shell = lambda: (setattr(fake, 'boot', fake.boot + 600), True)[1]
assert w.repair(fake, 'stack', 'test') == 0 and fake.locks == 1, 'a suspend while the shell was down locks the screen after'
fake = Fake()
assert w.repair(fake, 'stack', 'test') == 0 and fake.locks == 0
fake = Fake(); hang(fake); fake.mono_before = fake.mono
assert w.repair(fake, 'stack', 'test') == 1 and fake.order[-1] == 'start shell', 'a server that never answers again fails, and the shell still returns'
assert fake.mono - fake.mono_before >= w.RECOVERY
fake = Fake(); fake.restart_result = False
assert w.repair(fake, 'wireplumber', 'test') == 1 and fake.order == ['stop shell', 'restart wireplumber', 'start shell']
print('ok - restarts wait for an unlocked screen and bring the shell back')

# A single slow answer is not a hang.
fake = Fake(); watch = w.Watch(fake); run(watch, 60)
fake.healthy = False; watch.step(); fake.healthy = True
run(watch, 120)
assert fake.stack_restarts == 0
print('ok - one failed probe followed by an answer restarts nothing')

# The budget: never twice within two minutes, at most three times in half an
# hour, then one notice with a click to restart by hand, and no more automatic
# restarts until audio has answered again.
fake = Fake(); watch = w.Watch(fake); run(watch, 60)
hang(fake)
run(watch, 100)
assert fake.stack_restarts == 1 and not fake.notices, 'a restart that did not help claims nothing'
run(watch, 900)
assert fake.stack_restarts == 3, fake.stack_restarts
stuck = [notice for notice in fake.notices if notice[0] == 'Audio is not responding']
assert stuck == [('Audio is not responding', w.MANUAL)], fake.notices
logged = fake.runtime / 'omarchy-audio-repairs'; before = logged.read_text()
run(watch, 600)
assert fake.stack_restarts == 3 and len([n for n in fake.notices if n[0] == 'Audio is not responding']) == 1, 'the notice is sent once'
assert logged.read_text() == before, 'a spent budget is not retried every probe'
fake.healthy = True; run(watch, 120)
assert not watch.stuck, 'answers again clear the notice latch'
before = fake.stack_restarts
assert w.repair(fake, 'stack', 'clicked', manual=True) == 0 and fake.stack_restarts == before + 1, 'the notice click restarts despite the budget'
fake.locked = True
assert w.repair(fake, 'stack', 'clicked', manual=True) == w.DEFERRED, 'but never under the lock screen'
print('ok - restarts are spaced and capped, then the user is told once')

# Restarts are this login's only. A logout (or a session that is not the
# active one) stops judging at once, and a repair re-checks the session
# right before it acts.
fake = Fake(); watch = w.Watch(fake); run(watch, 60)
fake.healthy = False; fake.active = False; before = fake.probes
run(watch, 300)
assert fake.stack_restarts == 0 and fake.probes == before, (fake.stack_restarts, fake.probes)
fake = Fake(); watch = w.Watch(fake); run(watch, 60)
fake.healthy = False
checks = iter([True, True, False])
fake.session_active = lambda: next(checks, False)
watch.step(); fake.sleep(w.TICK); watch.step()
assert fake.stack_restarts == 0, 'a session that ends mid-check is not repaired'
print('ok - nothing restarts during or after a logout')

# Audio the user stopped (or a unit systemd is still starting) is not probed:
# a probe would socket-activate it. A unit that gave up (a crash loop hit its
# start limit) is a failure like a hang.
fake = Fake(); fake.unit_state = 'other'; watch = w.Watch(fake)
run(watch, 300)
assert fake.probes == 0 and fake.stack_restarts == 0
assert w.repair(fake, 'stack', 'test') == w.DEFERRED and fake.stack_restarts == 0, 'an automatic repair leaves stopped audio alone'
assert w.repair(fake, 'stack', 'clicked', manual=True) == 0, 'the user may start it'
fake = Fake(); watch = w.Watch(fake); run(watch, 60)
fake.unit_state = 'failed'; before = fake.probes
run(watch, 20)
assert fake.stack_restarts == 1 and fake.probes > before and fake.notices == [('Audio restarted', ())], (fake.stack_restarts, fake.notices)
print('ok - stopped or starting audio is left alone, a failed unit is restarted')

# Suspend stops CLOCK_MONOTONIC but not CLOCK_BOOTTIME: a failure seen before
# a suspend is forgotten, and the stack settles again after the resume.
fake = Fake(); watch = w.Watch(fake); run(watch, 60)
fake.healthy = False; watch.step(); assert watch.failures == 1
fake.boot += 8 * 3600; fake.sleep(w.TICK); watch.step()
assert watch.failures == 0 and fake.stack_restarts == 0
run(watch, 20)
assert fake.stack_restarts == 0, 'a resumed session settles first'
print('ok - a suspend in between forgets old failures')

# WirePlumber busy for a while only brings the next probe forward; its DSP
# threads may legitimately be busy. A wedged one fails the probes too.
fake = Fake(); watch = w.Watch(fake); run(watch, 40)
watch.next_probe = fake.mono + 10000; before = fake.probes; fake.wp_load = 1.0
run(watch, 10)
assert fake.probes == before, 'a moment of CPU is nothing'
run(watch, 30)
assert fake.probes == before + 1 and fake.stack_restarts == 0, 'a busy but answering WirePlumber is probed early and left alone'
fake.healthy = False
run(watch, 20)
assert fake.stack_restarts == 1
fake = Fake(); watch = w.Watch(fake); fake.wp_load = 1.0
for _ in range(3):
    watch.wireplumber_busy(fake.mono); fake.sleep(w.TICK)
assert watch.busy is not None
fake.wp_start = 99.0
assert not watch.wireplumber_busy(fake.mono) and watch.busy is None, 'a replaced WirePlumber starts a new CPU sample'
fake.wp = None
assert not watch.wireplumber_busy(fake.mono) and watch.cpu is None, 'a vanished WirePlumber is no sample'
print('ok - WirePlumber CPU only brings a probe forward')

# One lock and one budget for every automatic restart. The mapper's
# WirePlumber restarts run through the same command.
fake = Fake()
with w.repair_lock(fake) as held:
    assert held
    assert w.repair(fake, 'stack', 'test') == w.DEFERRED, 'a repair already running defers another'
assert fake.stack_restarts == 0
for attempt in range(3):
    fake.boot += 400
    assert w.repair(fake, 'wireplumber', 'links refused') == 0
fake.boot += 400
assert w.repair(fake, 'wireplumber', 'links refused') == w.EXHAUSTED and fake.wp_restarts == 3
fake.boot += 3600
assert w.repair(fake, 'stack', 'hung') == 0
fake.boot += 40
assert w.repair(fake, 'wireplumber', 'links refused') == w.DEFERRED, 'a fresh stack restart already rebuilt the graph'
fake.boot += 10
fake.active = False
assert w.repair(fake, 'stack', 'hung') == w.DEFERRED and fake.stack_restarts == 1
fake.active = True; fake.restart_result = False; fake.boot += 200
assert w.repair(fake, 'stack', 'hung') == 1
print('ok - mapper and watchdog restarts share one lock and budget')

# The real system seams: /proc parsing, the lock query failing closed, and
# the probe bound to the local Pulse socket.
system = w.System()
cpu, start = system.stat(os.getpid())
assert cpu >= 0 and 0 < start
assert system.stat(2**31) is None
with mock.patch.object(w.System, 'run', return_value=None):
    assert system.lock_state() == 'the lock state is unknown' and not system.probe() and not system.start_shell()
    assert system.units() == 'other'
def answers(locked, status):
    def run(self, *args, timeout=10, env=None):
        if args[0] == 'omarchy-hyprland-session-locked': return subprocess.CompletedProcess(args, locked, '', '')
        return None if status is None else subprocess.CompletedProcess(args, 0, status, '')
    return run
free = '{"secure":false,"requested":false}'
for locked, status, expected in ((1, free, None), (0, free, 'the screen is locked'), (2, free, 'the lock state is unknown'),
                                 (1, '{"secure":false,"requested":true}', 'the screen is locked'),
                                 (1, '{"secure":true,"requested":false}', 'the screen is locked'),
                                 (1, None, None), (1, 'garbage', 'the lock state is unknown')):
    with mock.patch.object(w.System, 'run', answers(locked, status)):
        assert system.lock_state() == expected, (locked, status)
with mock.patch.dict(os.environ, {'OMARCHY_PATH': '/usr/share/omarchy'}):
    # What Quickshell 0.3.1 prints for `list -j` when no instance runs.
    none = 'No running instances for "/usr/share/omarchy/shell/shell.qml"\nUse --all to list all instances.'
    for listings, result, kills in (([none], 'none', 0), (['[{}]', '[{}, {}]', '[{}]', none], 'stopped', 3),
                                    (['[]'], 'none', 0), (['[{}]'] * 11, 'failed', 10), ([None], 'unknown', 0),
                                    (['{}'], 'unknown', 0), (['garbage'], 'unknown', 0)):
        replies = iter(listings)
        calls = []
        def run(self, *args, timeout=10, env=None):
            calls.append(args)
            if args[1] == 'list':
                listing = next(replies, listings[-1])
                return None if listing is None else subprocess.CompletedProcess(args, 0, listing, '')
            return subprocess.CompletedProcess(args, 0, '', '')
        with mock.patch.object(w.System, 'run', run):
            assert system.stop_shell() == result, (listings, result)
        assert sum(call[1] == 'kill' for call in calls) == kills, (listings, calls)
        assert all(call[2:4] == ('-p', '/usr/share/omarchy/shell') for call in calls)
# Relocking asks until the new shell reports the lock taken, and gives up
# after half a minute.
clock = [0.0]
with mock.patch.object(w.System, 'monotonic', lambda self: clock[0]), \
        mock.patch.object(w.System, 'sleep', lambda self, seconds: clock.__setitem__(0, clock[0] + seconds)):
    replies = iter([None, '{"secure":false,"requested":false}', '{"requested":true}'])
    asked = []
    def run(self, *args, timeout=10, env=None):
        if args[2] == 'status':
            reply = next(replies)
            return None if reply is None else subprocess.CompletedProcess(args, 0, reply, '')
        asked.append(args); return subprocess.CompletedProcess(args, 0, '', '')
    with mock.patch.object(w.System, 'run', run):
        assert system.lock_screen() and len(asked) == 2, asked
    clock[0] = 0.0
    with mock.patch.object(w.System, 'run', return_value=None):
        assert not system.lock_screen() and clock[0] >= 30
for states, expected in (('active\nactive\nactive', 'active'), ('active\nfailed\nactive', 'failed'),
                         ('active\ninactive\nactive', 'other'), ('failed\nactivating\nactive', 'other')):
    with mock.patch.object(w.System, 'run', return_value=subprocess.CompletedProcess([], 3, states, '')):
        assert system.units() == expected, states
with mock.patch.object(w.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')) as call, \
        mock.patch.dict(os.environ, {'PULSE_SERVER': 'tcp:remote', 'XDG_RUNTIME_DIR': '/run/user/1000'}):
    assert w.System().probe()
    assert call.call_args.kwargs['env']['PULSE_SERVER'] == 'unix:/run/user/1000/pulse/native'
    assert call.call_args.kwargs['timeout'] == w.PROBE_TIMEOUT
with mock.patch.dict(os.environ, {'XDG_SESSION_ID': ''}):
    assert not system.session_active(), 'no session id fails closed'
with mock.patch.dict(os.environ, {'XDG_SESSION_ID': '7'}), \
        mock.patch.object(w.System, 'output', side_effect=['yes\nactive', 'no\nclosing', None]):
    assert system.session_active() and not system.session_active() and not system.session_active()
print('ok - system seams read /proc, logind and the lock state safely')

unit = (root / 'vendor/systemd/user/omarchy-audio-watchdog.service').read_text()
assert 'ExecStart=/usr/bin/omarchy-audio-watchdog --watch' in unit and 'PartOf=graphical-session.target' in unit
assert 'Wants=' not in unit and 'Requires=' not in unit, 'the watchdog never starts audio by itself'
assert any(line.startswith('After=') and 'graphical-session.target' in line.split('=', 1)[1].split() for line in unit.splitlines()), \
    'the watchdog starts once the session environment is in the user manager'
link = root / 'vendor/systemd/user/graphical-session.target.wants/omarchy-audio-watchdog.service'
assert link.is_symlink() and os.readlink(link) == '../omarchy-audio-watchdog.service'
with tempfile.TemporaryDirectory() as staged:
    subprocess.run([str(root / 'install'), staged], check=True)
    installed = Path(staged, 'usr/lib/systemd/user/graphical-session.target.wants/omarchy-audio-watchdog.service')
    assert installed.is_symlink() and installed.resolve() == Path(staged, 'usr/lib/systemd/user/omarchy-audio-watchdog.service').resolve()
    assert os.access(Path(staged, 'usr/bin/omarchy-audio-watchdog'), os.X_OK)
print('ok - the package turns the watchdog on for every user session')
PY
