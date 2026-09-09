#!/usr/bin/python3
"""Check an ARM channel snapshot before replacing any client configuration."""
import concurrent.futures
import hashlib
import json
import re
import sys
import subprocess

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
    packages = {p['name']: p for p in manifest['packages']}
    pair = {'omarchy-dev', 'omarchy-settings-dev'} if channel == 'edge' else {'omarchy', 'omarchy-settings'}
    if not pair | {'hyprland', 'hyprtoolkit', 'hyprland-guiutils'} <= packages.keys():
        raise ValueError('Channel lacks its desktop pair or compositor stack')
    if channel != 'edge' and {'omarchy-dev', 'omarchy-settings-dev'} & packages.keys():
        raise ValueError('Release channel contains development packages')
    if len({packages[name]['version'] for name in pair}) != 1:
        raise ValueError('Desktop/settings versions differ')
    if channel == 'stable' and 'rc' in packages['omarchy']['version']:
        raise ValueError('Stable contains a prerelease')
    for db in ('omarchy.db', 'omarchy-aarch64.db'):
        if hashlib.sha256(fetch(db)).hexdigest() != manifest['databases'][db]:
            raise ValueError('Channel database is incomplete or publication is still in progress')
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
