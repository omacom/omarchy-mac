#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
require_command python3
require_command curl
require_command bsdtar
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

validator = Path(sys.argv[1]) / 'install/helpers/arm-channel-manifest.py'
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    def setup(channel):
        names = ['hyprland', 'hyprtoolkit', 'hyprland-guiutils']
        names += ['omarchy-dev', 'omarchy-settings-dev'] if channel == 'edge' else ['omarchy', 'omarchy-settings']
        rows = []
        for name in names:
            filename = name + '-4.0.3-1-aarch64.pkg.tar.xz'
            (root / filename).write_bytes(b'fixture archive')
            rows.append(dict(name=name, version='4.0.3-1', filename=filename, sha256=hashlib.sha256(b'fixture archive').hexdigest()))
        databases = {}
        for filename in ('omarchy.db', 'omarchy-aarch64.db'):
            path = root / filename
            with tarfile.open(path, 'w:gz') as archive:
                for row in rows:
                    data = ''.join(f'%{key}%\n{row[value]}\n\n' for key, value in [('NAME', 'name'), ('VERSION', 'version'), ('FILENAME', 'filename'), ('SHA256SUM', 'sha256')]).encode()
                    member = tarfile.TarInfo(row['name'] + '-4.0.3-1/desc')
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
            databases[filename] = hashlib.sha256(path.read_bytes()).hexdigest()
        return dict(schema=1, client_protocol=1, bootstrap=False, channel=channel, packages=rows, databases=databases)
    def check(manifest, channel, succeeds):
        (root / 'channel-manifest.json').write_text(json.dumps(manifest))
        result = subprocess.run(['python3', str(validator), channel, root.as_uri()], capture_output=True, text=True)
        assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
    for channel in ('stable', 'rc', 'edge'):
        manifest = setup(channel)
        check(manifest, channel, True)
        broken = copy.deepcopy(manifest)
        broken['packages'].append(broken['packages'][0])
        check(broken, channel, False)
        broken = copy.deepcopy(manifest)
        broken['bootstrap'] = True
        check(broken, channel, False)
        broken = copy.deepcopy(manifest)
        broken['packages'][0]['version'] = 'other'
        check(broken, channel, False)
        with tarfile.open(root / 'omarchy.db', 'w:gz'):
            pass
        broken = copy.deepcopy(manifest)
        broken['databases']['omarchy.db'] = hashlib.sha256((root / 'omarchy.db').read_bytes()).hexdigest()
        check(broken, channel, False)
    manifest = setup('rc')
    (root / manifest['packages'][0]['filename']).unlink()
    check(manifest, 'rc', False)
print('ok - channel preflight verifies all channel identities, complete databases and available archives before switching')
PY
