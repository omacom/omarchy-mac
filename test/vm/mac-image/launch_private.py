"""Launch this qualification's read-only trust audit or admitted VM lanes."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

import admit
import disposable_payload
from audit_export import AUDIT_SHA256

ROOT = Path('/home/scott/code/omarchy-integration-evidence/encryption-limine-build-20260922')
ARTIFACT = ROOT / 'artifact-image-3'
BUILDER = Path('/tmp/quattro-limine-private-builder')
KERNELS = Path('/tmp/quattro-limine-vm-kernel')
HARNESS = Path(__file__).resolve().parent
IMAGE = 'sha256:9c3e8f21b3239755fc5f54401b30b4bf60b7d20b687b12c9ab1b13e985ee597c'
AUDIT = ROOT / 'tooling/audit-private-limine-trust.py'
AUDIT_REPORT = ROOT / 'vm/shipping-trust-audit-image-3.json'
STATE = ROOT / 'vm/state-attempt-1'
EVIDENCE = ROOT / 'vm/run-attempt-1'
HOST_RULE = Path('/run/udev/rules.d/99-omarchy-private-limine-20260922.rules')
HOST_RULE_SHA256 = '52f6603520f1c28ff0805d2a1157abed4391c6b19c44b01c39f8a4331676b054'


def require_host_rule():
    admit.require(HOST_RULE.is_file() and not HOST_RULE.is_symlink(),
                  'reviewed temporary host loop rule is absent; install and probe it before launching')
    admit.require(admit.digest_file(HOST_RULE) == HOST_RULE_SHA256,
                  'temporary host loop rule differs from reviewed v3 bytes; refusing launch')


def mount_args(source, *, writable=False):
    source = Path(source)
    admit.require(source.exists() and not source.is_symlink(), f'unsafe/missing mount input: {source}')
    return ['--mount', f'type=bind,src={source},dst={source}' + ('' if writable else ',readonly')]


def command(args):
    pin, _ = admit.descriptor(args.inputs, args.inputs_sha256)
    admit.require(admit.digest_file(ARTIFACT / 'package-evidence.json') == pin['image_verification_sha256'], 'unbound exported image report')
    admit.require(admit.digest_file(AUDIT) == AUDIT_SHA256, 'trust audit implementation changed')
    common = ['docker', 'run', '--rm', '--privileged', '--network', 'none',
              '--mount', 'type=bind,src=/run/udev,dst=/run/udev,readonly',
              '--mount', 'type=bind,src=/proc/1/mountinfo,dst=/host-mountinfo,readonly']
    for source in (HARNESS, args.inputs, ARTIFACT, AUDIT):
        common += mount_args(source)
    common += mount_args(ROOT / 'vm', writable=True)
    if args.stage == 'audit':
        admit.require(not AUDIT_REPORT.exists(), 'trust audit report already exists')
        return common + [IMAGE, 'python3', str(HARNESS / 'audit_export.py'), '--inputs', str(args.inputs),
                        '--inputs-sha256', args.inputs_sha256, '--artifact-root', str(ARTIFACT), '--audit-tool', str(AUDIT)]
    report = admit.strict_json(AUDIT_REPORT.read_bytes())
    admit.require(report['kind'] == 'private-limine-export-trust-audit' and report['result'] == 'passed'
                  and report['inputs_sha256'] == args.inputs_sha256 and report['audit_tool_sha256'] == AUDIT_SHA256,
                  'VM requires this descriptor to pass the shipping trust audit')
    admit.require(not STATE.exists() and not EVIDENCE.exists(), 'VM attempt directories already exist')
    admit.require(shutil.disk_usage(ROOT / 'vm').free > 19 * 1024**3, 'more than 19 GiB free required before VM admission; checked again afterward')
    git_common = Path(subprocess.check_output(['git', '-C', str(BUILDER), 'rev-parse', '--git-common-dir'], text=True).strip()).resolve()
    for source in (BUILDER, git_common, KERNELS, ROOT / 'candidate-signed', ROOT / 'dependencies-signed'):
        common += mount_args(source)
    common += ['--tmpfs', '/admission-tmp:rw,nosuid,nodev,noexec,size=3g,mode=0700']
    product = admit.strict_json((ARTIFACT / 'product.json').read_bytes())
    kernel = pin['generic_kernel']['filename']
    payload = ARTIFACT / product['package_filename']
    guest = [IMAGE, str(HARNESS / 'run'), '--state', str(STATE), '--evidence', str(EVIDENCE)]
    if args.disposable_payload is not None:
        payload = args.disposable_payload.absolute()
        package = admit.strict_json((ARTIFACT / 'package-evidence.json').read_bytes())['package']
        receipt = disposable_payload.inspect(payload, package, args.inputs_sha256, os.getuid())
        disposable_payload.require_memory(ROOT / 'candidate-signed', ROOT / 'dependencies-signed')
        # A directory bind permits unlink+close to release tmpfs pages. A file
        # bind would keep the ZIP inode pinned for the lifetime of the container.
        common += mount_args(payload.parent, writable=True)
        guest += ['--disposable-payload-receipt', json.dumps(receipt, sort_keys=True)]
    if args.only:
        guest += ['--only', args.only]
    guest += ['--', '--inputs', str(args.inputs), '--inputs-sha256', args.inputs_sha256,
              '--builder', str(BUILDER), '--candidate-root', str(ROOT / 'candidate-signed'),
              '--dependency-root', str(ROOT / 'dependencies-signed'), '--payload', str(payload),
              '--product', str(ARTIFACT / 'product.json'), '--verification', str(ARTIFACT / 'package-evidence.json'),
              '--generic-kernel', str(KERNELS / kernel), '--generic-kernel-signature', str(KERNELS / (kernel + '.sig')),
              '--members-source', str(ARTIFACT / 'payload'), '--snapshot-tmpfs', '/admission-tmp']
    return common + guest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('audit', 'vm'))
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--inputs-sha256', required=True)
    parser.add_argument('--only', choices=('plain', 'encrypted'))
    parser.add_argument('--disposable-payload', type=Path, help='explicit owned tmpfs ZIP; securely released after successful admission')
    parser.add_argument('--print-command', action='store_true')
    args = parser.parse_args()
    args.inputs = args.inputs.absolute()
    admit.require(args.stage == 'vm' or args.disposable_payload is None, 'disposable payload is only valid for VM execution')
    invocation = command(args)
    if args.print_command:
        print(shlex.join(invocation))
        return
    # Fail before starting a container or attaching its first loop. Post-attach
    # per-device checks still prove that the loaded host rule actually applied.
    require_host_rule()
    log = AUDIT_REPORT if args.stage == 'audit' else ROOT / 'vm/vm-attempt-1-launch.log'
    with log.open('x') as output, Path(str(log) + '.stderr').open('x') as errors:
        result = subprocess.run(invocation, stdout=output, stderr=errors)
    if result.returncode:
        raise SystemExit(f'{args.stage} failed ({result.returncode}); inspect {log}.stderr')
    print(log)


if __name__ == '__main__':
    main()
