#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# The native transaction cases belong in a contained uid-0 test process. All
# packages, repositories and the pacman root are synthetic and disk-backed.
if (( EUID != 0 )) || ! command -v repo-add >/dev/null; then
  pass 'native ARM channel transactions require the contained root test runner'
  exit 0
fi
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export CHANNEL_TEST_ROOT="$ROOT" CHANNEL_TEST_STORAGE="$test_tmp"
python3 - <<'PY'
import io, os, pathlib, subprocess, tarfile

root = pathlib.Path(os.environ['CHANNEL_TEST_ROOT'])
work = pathlib.Path(os.environ['CHANNEL_TEST_STORAGE'])
lanes = work / 'lanes'
guest = work / 'guest'
for d in ['db/local', 'cache', 'etc', 'hooks', 'log', 'keyring']:
    (guest / d).mkdir(parents=True)
(guest / 'db/local/ALPM_DB_VERSION').write_text('9\n')
for d in ['stable', 'rc', 'edge', 'regular', 'graphics', 'baseline']:
    (lanes / d).mkdir(parents=True)

def run(argv, **kw):
    p = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kw)
    if p.returncode:
        raise AssertionError(f'{argv}: exit {p.returncode}\n{p.stdout}')
    return ''.join(line for line in p.stdout.splitlines(True) if not line.startswith('warning:'))

def pkg(lane, name, version, *metadata):
    content = work / f'build-{lane}-{name}'
    content.mkdir()
    data = f'pkgname = {name}\npkgver = {version}\npkgdesc = channel fixture\narch = aarch64\nbuilddate = 1\nsize = 1\n'
    (content / '.PKGINFO').write_text(data + ''.join(f'{x}\n' for x in metadata))
    (content / f'{name}.txt').write_text(f'{name} {version}\n')
    archive = lanes / lane / f'{name}-{version}-aarch64.pkg.tar.zst'
    run(['bsdtar', '--zstd', '-cf', str(archive), '-C', str(content), '.PKGINFO', f'{name}.txt'])
    return archive

base = []
for name in ['omarchy', 'omarchy-settings']:
    base.append(pkg('baseline', name, '4.0.2-2'))
for name in ['hyprland', 'hyprtoolkit', 'hyprland-guiutils', 'aquamarine', 'ordinary', 'old-widget']:
    base.append(pkg('baseline', name, '1-1'))
for lane, version in [('stable', '4.0.2-2'), ('rc', '4.0.3rc1-1'), ('edge', '4.0.3rc1-1')]:
    pkg(lane, 'omarchy', version, 'depend = newlib')
    pkg(lane, 'omarchy-settings', version)
    run(['repo-add', str(lanes / lane / 'omarchy-aarch64.db.tar.gz'), *map(str, (lanes / lane).glob('*.pkg.tar.zst'))])
for name in ['hyprland', 'hyprtoolkit', 'hyprland-guiutils']:
    pkg('graphics', name, '2-1', 'depend = aquamarine=2-1')
run(['repo-add', str(lanes / 'graphics/omarchy.db.tar.gz'), *map(str, (lanes / 'graphics').glob('*.pkg.tar.zst'))])
for name in ['aquamarine', 'ordinary', 'newlib']:
    pkg('regular', name, '2-1')
pkg('regular', 'new-widget', '2-1', 'replaces = old-widget', 'conflict = old-widget')
run(['repo-add', str(lanes / 'regular/extra.db.tar.gz'), *map(str, (lanes / 'regular').glob('*.pkg.tar.zst'))])

# A real local signing key verifies that preflight and final install can use
# copied public trust without copying the source secret key or mutating it.
# The runner maps this verified disk directory at /tmp too; use its shorter
# alias so Unix agent socket names remain below sockaddr_un limits.
keyring = pathlib.Path('/tmp') / work.name / 'guest/keyring'
assert keyring.samefile(guest / 'keyring'), 'contained runner must bind its disk TMPDIR at /tmp'
keyring.chmod(0o700)
gpg = ['gpg', '--homedir', str(keyring), '--batch', '--pinentry-mode', 'loopback', '--passphrase', '']
run([*gpg, '--quick-generate-key', 'Channel fixture <channel@fixture.invalid>', 'ed25519', 'sign', '0'])
for lane in ['stable', 'rc', 'edge']:
    archives = list((lanes / lane).glob('*.pkg.tar.zst'))
    for archive in archives:
        run([*gpg, '--detach-sign', str(archive)])
    run(['repo-add', str(lanes / lane / 'omarchy-aarch64.db.tar.gz'), *map(str, archives)])
run(['gpgconf', '--homedir', str(keyring), '--kill', 'gpg-agent'])
key_files = {p.name: p.read_bytes() for p in keyring.iterdir() if p.is_file()}

transport = work / 'transport.py'
transport.write_text('''import os, pathlib, shutil, sys
base = pathlib.Path(sys.argv[1]); url, dest = sys.argv[2:]
if '/releases/download/' in url:
    lane, name = url.split('/releases/download/', 1)[1].split('/', 1)
elif 'pkgs.omarchy.org' in url:
    lane, name = 'graphics', url.rsplit('/', 1)[1]
else:
    lane, name = 'regular', url.rsplit('/', 1)[1]
source = base / lane / name
if not source.is_file(): sys.exit(1)
shutil.copyfile(source, dest)
if os.environ.get('CHANNEL_MUTATE_SOURCE') == '1' and lane == 'rc' and name.startswith('omarchy-4.'):
    source.write_bytes(source.read_bytes() + b'changed-after-download')
    (base / 'rc/omarchy-aarch64.db').write_bytes((base / 'stable/omarchy-aarch64.db').read_bytes())
''')
config = guest / 'etc/pacman.conf'
config.write_text(f'''[options]
RootDir = {guest}
DBPath = {guest}/db
CacheDir = {guest}/cache
LogFile = {guest}/log/pacman.log
HookDir = {guest}/hooks
GPGDir = {keyring}
Architecture = aarch64
SigLevel = Never
LocalFileSigLevel = Never
XferCommand = /usr/bin/python3 {transport} {lanes} %u %o
[extra]
Server = https://regular.invalid/$repo/$arch
[omarchy-aarch64]
SigLevel = Required DatabaseOptional
Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge
''')
pacman = ['pacman', '--config', str(config)]
run([*pacman, '-U', '--noconfirm', *map(str, base)])
run([*pacman, '-D', '--asdeps', 'aquamarine'])
original = config.read_bytes()
def sync_state():
    return {p.relative_to(guest / 'db/sync').as_posix(): p.read_bytes() for p in (guest / 'db/sync').glob('**/*') if p.is_file()}
original_sync = sync_state()
stub = work / 'bin'; stub.mkdir()
(stub / 'sudo').write_text('#!/bin/bash\nexec "$@"\n')
(stub / 'sudo').chmod(0o755)
env = dict(os.environ, PATH=f'{stub}:' + os.environ['PATH'], OMARCHY_PACMAN_CONFIG=str(config))
# These native fixtures test resolver/transaction behavior with unsigned local
# packages. Production's required graphics signatures remain unchanged.
script = '''source "$2/install/helpers/arm-package-sources.sh"
omarchy_arm_package_repo() {
  printf '%s\\n' '[omarchy]' 'Usage = Sync' 'SigLevel = Never' 'Server = https://pkgs.omarchy.org/edge/$arch'
}
source "$2/install/helpers/arm-channel.sh"
omarchy_arm_channel_apply "$1"
'''
def channel(lane, success=True):
    p = subprocess.run(['bash', '-euo', 'pipefail', '-c', script, 'bash', lane, str(root)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (work / f'{lane}-{success}.log').write_text(p.stdout)
    if (p.returncode == 0) != success:
        raise AssertionError(f'channel {lane}: {p.returncode}\n{p.stdout}')
    return p.stdout

# A missing lane must fail before modifying config or installed packages.
db = lanes / 'rc/omarchy-aarch64.db'
saved = db.read_bytes(); db.unlink()
before = run([*pacman, '-Q'])
channel('rc', False)
assert config.read_bytes() == original and run([*pacman, '-Q']) == before
db.write_bytes(saved)
print('ok - absent lane leaves active config and installed packages untouched')

# Metadata for only one of the pair is not a usable lane.
buffer = io.BytesIO()
with tarfile.open(fileobj=io.BytesIO(saved)) as old, tarfile.open(fileobj=buffer, mode='w:gz') as new:
    for item in old.getmembers():
        if item.name.startswith('omarchy-settings-'): continue
        new.addfile(item, old.extractfile(item) if item.isfile() else None)
db.write_bytes(buffer.getvalue())
channel('rc', False)
assert config.read_bytes() == original and run([*pacman, '-Q']) == before
db.write_bytes(saved)
print('ok - a lane missing one desktop package cannot change installed state or config')

archive = next((lanes / 'rc').glob('omarchy-4.*.pkg.tar.zst'))
archive_bytes = archive.read_bytes()
archive.unlink()
channel('rc', False)
assert config.read_bytes() == original and run([*pacman, '-Q']) == before
archive.write_bytes(archive_bytes + b'corrupt-archive')
channel('rc', False)
assert config.read_bytes() == original and run([*pacman, '-Q']) == before
archive.write_bytes(archive_bytes)
print('ok - missing or hash-mismatched archives fail before any package is installed')

# libalpm detects an unowned-file collision at transaction commit, after the
# resolver/download preflight. Neither member of the pair may be installed.
collision = guest / 'newlib.txt'
collision.write_text('administrator file\n')
failure_output = channel('rc', False)
assert config.read_bytes() == original and run([*pacman, '-Q']) == before, failure_output + '\nBEFORE:\n' + before + '\nAFTER:\n' + run([*pacman, '-Q'])
assert collision.read_text() == 'administrator file\n'
assert sync_state() == original_sync, 'failed transaction must restore preexisting sync databases\n' + failure_output
collision.unlink()
print('ok - a real file-conflict transaction failure preserves both packages and active configuration')

env['CHANNEL_MUTATE_SOURCE'] = '1'
for cached in (guest / 'cache').glob('*.pkg.tar.zst*'):
    cached.unlink()
channel('rc')
del env['CHANNEL_MUTATE_SOURCE']
assert archive.read_bytes() != archive_bytes and db.read_bytes() != saved
archive.write_bytes(archive_bytes)
db.write_bytes(saved)
assert 'download/rc' in config.read_text()
assert run([*pacman, '-Q', 'omarchy', 'omarchy-settings']).splitlines() == ['omarchy 4.0.3rc1-1', 'omarchy-settings 4.0.3rc1-1']
assert 'ordinary 2-1' in run([*pacman, '-Q', 'ordinary'])
assert 'new-widget 2-1' in run([*pacman, '-Q', 'new-widget'])
assert subprocess.run([*pacman, '-Q', 'old-widget'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
deps = run([*pacman, '-Qqd']).splitlines()
assert 'aquamarine' in deps and 'newlib' in deps
assert 'ordinary' in run([*pacman, '-Qqe']).splitlines()
assert config.read_text().index('[extra]') < config.read_text().index('[omarchy-aarch64]')
print('ok - frozen native transaction upgrades both packages, dependencies and replacements while preserving install reasons')
print('ok - same-version source bytes and lane DB mutation after download cannot change the frozen transaction')

channel('stable')
assert 'download/stable' in config.read_text()
assert run([*pacman, '-Q', 'omarchy', 'omarchy-settings']).splitlines() == ['omarchy 4.0.2-2', 'omarchy-settings 4.0.2-2']
assert 'ordinary 2-1' in run([*pacman, '-Q', 'ordinary'])
print('ok - rc to stable downgrades only the explicit pair while retaining the upgraded distribution stack')
assert all((keyring / name).read_bytes() == data for name, data in key_files.items())
print('ok - signed package preflight and installation preserve original public trust and secret keys')

# libalpm can return zero after a failed post-transaction hook. The hook runs
# inside the synthetic RootDir; its intentionally absent executable is inert.
(guest / 'hooks/99-fixture-fail.hook').write_text('''[Trigger]
Operation = Upgrade
Type = Package
Target = omarchy
[Action]
Description = Fixture posttransaction failure
When = PostTransaction
Exec = /fixture-does-not-exist
''')
previous_config = config.read_bytes()
previous_sync = sync_state()
output = channel('rc', False)
assert config.read_bytes() == previous_config
assert sync_state() == previous_sync, 'hook failure must restore original lane sync databases'
assert run([*pacman, '-Q', 'omarchy']).strip() == 'omarchy 4.0.3rc1-1'
assert 'transaction/hook error' in output, output
print('ok - posttransaction hook failure reports partial state and does not commit channel success')
PY
