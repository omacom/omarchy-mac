"""Audit the exported shipping trees through one tracked read-only loop."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import admit
import loop_guard

SYS_BLOCK = Path('/sys/block')
AUDIT_SHA256 = '1d70224e690a6df35e1c54e5f84fd83304c7f7c7bc2811b86081de4caa2b22d8'


def audit(args):
    pin, _ = admit.descriptor(args.inputs, args.inputs_sha256)
    artifact = args.artifact_root
    root_image = artifact / 'payload/root.img'
    verification = artifact / 'package-evidence.json'
    admit.require(admit.digest_file(verification) == pin['image_verification_sha256'], 'unbound image verification')
    admit.require(admit.digest_file(args.audit_tool) == AUDIT_SHA256, 'trust audit tool differs from reviewed bytes')
    report = admit.strict_json(verification.read_bytes())
    image = report['members']['root.img']
    admit.require(root_image.is_file() and not root_image.is_symlink(), 'unsafe exported root image')
    before = admit.digest_file(root_image)
    admit.require(root_image.stat().st_size == image['size_bytes'] and before == image['sha256'], 'exported root bytes differ')
    device = None
    mounted = []
    temporary = None
    trees = []
    try:
        device = subprocess.check_output(['losetup', '--find', '--show', '--read-only', str(root_image)], text=True).strip()
        guard = loop_guard.wait(device, root_image)
        admit.require((SYS_BLOCK / Path(device).name / 'ro').read_text().strip() == '1', 'audit loop is writable')
        temporary = Path(tempfile.mkdtemp(prefix='private-limine-shipping-audit-'))
        trees = [temporary / 'root', temporary / 'factory']
        for subvolume, target in zip(('@', '@factory'), trees):
            target.mkdir()
            subprocess.run(['mount', '-t', 'btrfs', '-o', 'ro,rescue=nologreplay,subvol=' + subvolume, device, str(target)], check=True)
            mounted.append(target)
        result = subprocess.run([sys.executable, str(args.audit_tool), '--root-tree', str(trees[0]), '--factory-tree', str(trees[1])], capture_output=True, text=True, check=True)
        trust = admit.strict_json(result.stdout)
        admit.require(trust['result'] == 'passed' and set(trust['trees']) == {'root', 'factory'}, 'incomplete shipping trust audit')
    finally:
        # Detach only the recorded loop if its identity still names this exact export.
        for target in reversed(mounted):
            subprocess.run(['umount', str(target)], check=True)
        if device is not None:
            backing = SYS_BLOCK / Path(device).name / 'loop/backing_file'
            admit.require(backing.read_text().strip() == str(root_image), 'audit loop identity changed; refusing detach')
            subprocess.run(['losetup', '--detach', device], check=True)
            loop_guard.wait_released(device, root_image, sys_block=SYS_BLOCK)
        for target in trees:
            if target.exists(): target.rmdir()
        if temporary is not None: temporary.rmdir()
    after = admit.digest_file(root_image)
    admit.require(after == before, 'read-only audit changed exported bytes')
    print(json.dumps({'kind': 'private-limine-export-trust-audit', 'result': 'passed',
        'inputs_sha256': args.inputs_sha256, 'audit_tool_sha256': AUDIT_SHA256,
        'root_image_sha256_before': before, 'root_image_sha256_after': after,
        'mount_options': ['ro', 'rescue=nologreplay', 'subvol=@', 'subvol=@factory'],
        'loop_guard': guard, 'shipping_trust': trust}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('inputs', 'artifact-root', 'audit-tool'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--inputs-sha256', required=True)
    audit(parser.parse_args())
