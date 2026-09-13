#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile
root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as temporary:
    work = Path(temporary); fixture = work / 'fixture'; fixture.mkdir()
    (fixture / 'channel').write_text('stable\n')
    (fixture / 'channel-stable').mkdir()
    (fixture / 'channel-stable/pkg.tar.zst').write_bytes(b'actual fixture bytes')
    log = work / 'log'
    real_curl = work / 'real-curl'
    real_curl.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$TRANSPORT_LOG"\nif [[ "$*" == *file://* ]]; then /usr/bin/curl "$@"; fi\n')
    real_curl.chmod(0o755)
    real_pacman = work / 'real-pacman'
    real_pacman.write_text('#!/bin/bash\n[[ $1 == --config ]] || exit 1\ncat "$2" > "$TRANSPORT_LOG"\nprintf "%s\\n" "$@" >> "$TRANSPORT_LOG"\n')
    real_pacman.chmod(0o755)
    original = (root / 'test/vm/channel-download').read_text()
    adapter = original.replace('/opt/omarchy-ci-channel', str(fixture)).replace('/usr/bin/curl', str(real_curl)).replace('/usr/bin/pacman', str(real_pacman))
    for name in ('curl', 'pacman'):
        path = work / name; path.write_text(adapter); path.chmod(0o755)
    env = dict(os.environ, TRANSPORT_LOG=str(log))
    prefix = 'https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/channel-'
    output = work / 'download.part'
    subprocess.run([str(work / 'curl'), '-fL', '-o', str(output), prefix + 'stable/pkg.tar.zst'], check=True, env=env, capture_output=True)
    assert output.read_bytes() == b'actual fixture bytes'
    assert str(output) in log.read_text(), 'pacman .part output must be preserved'
    for url in ('https://mirror.example/aarch64/core.db', 'https://github.com/other/repo/archive/main.tar.gz'):
        subprocess.run([str(work / 'curl'), url], check=True, env=env)
        assert log.read_text().strip() == url, 'unrelated requests must pass unchanged'
    for suffix in ('stable/missing', 'rc/pkg.tar.zst', 'stable/../secret'):
        previous = log.read_bytes()
        result = subprocess.run([str(work / 'curl'), prefix + suffix], env=env, capture_output=True)
        assert result.returncode != 0 and log.read_bytes() == previous, 'missing fixture must never fall back to public network'
    config = work / 'pacman.conf'
    for text in ('[options]\n[core]\nServer = https://base.example\n', '[options]\nColor\n[extra]\nServer = https://base.example\n'):
        config.write_text(text)
        subprocess.run([str(work / 'pacman'), '--config', str(config), '-Sy'], check=True, env=env)
        assert config.read_text() == text, 'adapter must not alter original/restored configuration'
        assert 'XferCommand = /usr/local/bin/curl -fL -o %o %u' in log.read_text()
        assert '-Sy' in log.read_text()
    assert 'python' not in original, 'transport must work before installer bootstraps Python'
harness = (root / 'test/vm/run-selective-edge').read_text()
transport = harness.split('install_fixture_transport() {', 1)[1].split('\n}', 1)[0]
assert 'pacman -S --needed' not in transport, 'fresh restore must not hide installer dependency bootstrap'
assert harness.count('restore_clean_guest\n') == 2, 'fixture and package phases need independent clean roots'
assert 'channel-manifest.json' in harness and 'build-output' in harness
print('ok - isolated channel transport preserves real bytes, config restoration and fail-closed routing')
PY
