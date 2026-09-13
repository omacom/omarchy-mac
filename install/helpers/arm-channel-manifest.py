#!/usr/bin/python3
"""Check an ARM channel snapshot before replacing any client configuration."""
import concurrent.futures
import hashlib
import json
import re
import sys
import subprocess
import tempfile
from pathlib import Path

channel, base = sys.argv[1:]
if channel not in ('stable', 'rc', 'edge'):
    raise SystemExit('Invalid ARM channel')
try:
    def fetch(name, head=False):
        if not re.fullmatch(r'[A-Za-z0-9@_+.-]+', name):
            raise ValueError('Unsafe snapshot filename')
        command = ['curl', '--fail', '--silent', '--show-error', '--location', '--max-time', '30']
        if head:
            command.append('--head')
        return subprocess.run([*command, base + '/' + name], check=True, capture_output=True).stdout

    manifest = json.loads(fetch('channel-manifest.json'))
    if manifest['schema'] != 1 or manifest['channel'] != channel:
        raise ValueError('Channel manifest identity does not match the requested channel')
    if manifest.get('client_protocol') != 1 or manifest.get('bootstrap'):
        raise ValueError('Historical baseline is not ready for channel switching')
    packages = {p['name']: p for p in manifest['packages']}
    if len(packages) != len(manifest['packages']):
        raise ValueError('Duplicate package identities in channel manifest')
    pair = {'omarchy-dev', 'omarchy-settings-dev'} if channel == 'edge' else {'omarchy', 'omarchy-settings'}
    if not pair | {'hyprland', 'hyprtoolkit', 'hyprland-guiutils'} <= packages.keys():
        raise ValueError('Channel lacks its desktop pair or compositor stack')
    if channel != 'edge' and {'omarchy-dev', 'omarchy-settings-dev'} & packages.keys():
        raise ValueError('Release channel contains development packages')
    if len({packages[name]['version'] for name in pair}) != 1:
        raise ValueError('Desktop/settings versions differ')
    if channel == 'stable' and 'rc' in packages['omarchy']['version']:
        raise ValueError('Stable contains a prerelease')
    expected = {p['name']: (p['version'], p['filename'], p['sha256']) for p in packages.values()}
    with tempfile.TemporaryDirectory() as temporary:
        for db in ('omarchy.db', 'omarchy-aarch64.db'):
            data = fetch(db)
            if hashlib.sha256(data).hexdigest() != manifest['databases'][db]:
                raise ValueError('Channel database is incomplete or publication is still in progress')
            path = Path(temporary) / db
            path.write_bytes(data)
            members = subprocess.run(['bsdtar', '-tf', str(path)], check=True, capture_output=True, text=True).stdout.splitlines()
            actual = {}
            for member in members:
                if not member.endswith('/desc'):
                    continue
                lines = subprocess.run(['bsdtar', '-xOf', str(path), member], check=True, capture_output=True, text=True).stdout.splitlines()
                fields = {line: lines[i + 1] for i, line in enumerate(lines[:-1]) if line.startswith('%')}
                name = fields['%NAME%']
                if name in actual:
                    raise ValueError('Duplicate package identity in channel database')
                actual[name] = (fields['%VERSION%'], fields['%FILENAME%'], fields['%SHA256SUM%'])
            if actual != expected:
                raise ValueError('Channel database differs from the declared package inventory')
    files = []
    for package in packages.values():
        if not re.fullmatch(r'[0-9a-f]{64}', package['sha256']):
            raise ValueError('Invalid package digest')
        files.append(package['filename'])
        if 'signature_sha256' in package:
            files.append(package['filename'] + '.sig')
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
        list(workers.map(lambda filename: fetch(filename, head=True), files))
except Exception as error:
    raise SystemExit(f'ARM {channel} snapshot is unavailable or incomplete: {error}')
