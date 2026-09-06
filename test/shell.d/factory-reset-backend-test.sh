#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
require_command python3

python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
source = (root / 'bin/omarchy-system-factory-reset').read_text()

with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary)
    binaries = fixture / 'bin'
    binaries.mkdir()
    calls = fixture / 'calls'
    home = fixture / 'home'
    home.mkdir()

    def executable(name, contents):
        path = binaries / name
        path.write_text('#!/bin/bash\n' + contents)
        path.chmod(0o755)

    # Probe availability without discovering packages on the machine running
    # the test. btrfs is the first existing main() check and stops a supported
    # fixture before a reset can proceed.
    executable('omarchy-cmd-present', '''
printf 'probe:%s\\n' "$*" >>"$RESET_TEST_CALLS"
for requested in "$@"; do
  [[ $requested != "$RESET_TEST_MISSING" && $requested != btrfs ]] || exit 1
done
''')

    # Every possible mutation is denied; unsupported fixtures must not even
    # attempt one. This also makes a regressed guard safe to test.
    for name in ('sudo', 'touch', 'chmod', 'mkdir', 'mount', 'umount', 'rmdir',
                 'btrfs', 'cryptsetup', 'systemctl', 'install', 'cp', 'mv',
                 'rm', 'userdel', 'passwd', 'chroot', 'sync', 'tee'):
        executable(name, 'printf "blocked:%s\\n" "${0##*/}" >>"$RESET_TEST_CALLS"\nexit 91\n')
    executable('mountpoint', 'exit 1\n')

    # Redirect the fixed boot paths into a fake filesystem. Do not add test
    # overrides to a privileged production command.
    pattern = r'/boot/efi/limine\.conf|/boot/limine\.conf|/efi/limine\.conf|/boot/grub'
    isolated_source = re.sub(pattern, lambda match: shlex.quote(str(fixture) + match[0]), source)
    isolated_source = isolated_source.replace('LOG_FILE=/var/log/omarchy-system-factory-reset.log',
                                              'LOG_FILE=' + shlex.quote(str(fixture / 'reset.log')))
    isolated_source = isolated_source.replace('TOP_MNT=/run/omarchy-system-factory-reset/top',
                                              'TOP_MNT=' + shlex.quote(str(fixture / 'top')))
    ordinary = fixture / 'reset'
    ordinary.write_text(isolated_source)

    # Simulate the second invocation after sudo. Only the elevation block is
    # removed; backend guards, their ordering, and all reset code stay intact.
    elevated_source, replacements = re.subn(
        r'^if \(\( EUID != 0 \)\); then\n.*?^fi\n',
        '# Test fixture: already elevated.\n', isolated_source,
        count=1, flags=re.MULTILINE | re.DOTALL)
    assert replacements == 1, 'the elevation boundary must remain identifiable'
    elevated = fixture / 'reset-elevated'
    elevated.write_text(elevated_source)

    # An existing baseline/key is deliberately insufficient: rejection must
    # preserve both, including when Limine tools were also installed on GRUB.
    (fixture / 'top/@factory').mkdir(parents=True)
    baseline = fixture / 'top/@factory/baseline'
    baseline.write_text('factory content\n')
    key = fixture / 'disk-key'
    key.write_text('original key\n')
    env = {**os.environ, 'HOME': str(home), 'OMARCHY_PATH': str(fixture),
           'PATH': str(binaries) + ':/usr/bin:/bin',
           'RESET_TEST_CALLS': str(calls)}

    def run(script, missing=''):
        calls.write_text('')
        return subprocess.run(['bash', str(script)],
                              env={**env, 'RESET_TEST_MISSING': missing},
                              capture_output=True, text=True)

    def rejected(description, script=elevated, missing=''):
        result = run(script, missing)
        assert result.returncode == 1, (description, result)
        assert 'supports Limine installations only' in result.stderr, result.stderr
        assert 'GRUB/Asahi' in result.stderr, result.stderr
        assert 'blocked:' not in calls.read_text(), calls.read_text()
        assert 'probe:btrfs' not in calls.read_text(), calls.read_text()
        assert not (fixture / 'reset.log').exists()
        assert baseline.read_text() == 'factory content\n'
        assert key.read_text() == 'original key\n'
        print('ok - ' + description)

    for missing in ('limine', 'limine-mkinitcpio'):
        rejected(f'missing {missing} refuses reset before sudo and mutations', ordinary, missing)

    rejected('installed tools without a Limine boot configuration refuse reset')
    grub = fixture / 'boot/grub'
    grub.mkdir(parents=True)
    (grub / 'grub.cfg').write_text('GRUB fixture\n')
    rejected('GRUB refuses reset even with Limine tools and a factory snapshot')

    limine = fixture / 'boot/limine.conf'
    limine.write_text('Limine fixture\n')
    rejected('ambiguous GRUB and Limine boot files refuse reset without mutation')
    (grub / 'grub.cfg').unlink()
    grub.rmdir()
    limine.unlink()

    for mount in ('boot', 'efi', 'boot/efi'):
        config = fixture / mount / 'limine.conf'
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text('Limine fixture\n')
        result = run(elevated)
        assert result.returncode == 1, result
        assert 'btrfs-progs is required' in result.stderr, result.stderr
        assert 'probe:btrfs' in calls.read_text(), calls.read_text()
        assert 'supports Limine' not in result.stderr, result.stderr
        assert not (fixture / 'reset.log').exists()
        config.unlink()
        print(f'ok - supported Limine /{mount} layout reaches existing reset validation')
PY
