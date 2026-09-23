import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import launch_private as launch


class LaunchRuleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.rule = self.root / 'reviewed.rules'
        self.expected = hashlib.sha256(b'reviewed host rule\n').hexdigest()

    def tearDown(self):
        self.temporary.cleanup()

    def check(self):
        with patch.object(launch, 'HOST_RULE', self.rule), patch.object(launch, 'HOST_RULE_SHA256', self.expected):
            launch.require_host_rule()

    def test_missing_rule_refuses_before_execution(self):
        with self.assertRaisesRegex(ValueError, 'absent'):
            self.check()

    def test_changed_rule_refuses_before_execution(self):
        self.rule.write_bytes(b'broader or stale rule\n')
        with self.assertRaisesRegex(ValueError, 'differs'):
            self.check()

    def test_symlink_to_matching_rule_is_rejected(self):
        target = self.root / 'target'
        target.write_bytes(b'reviewed host rule\n')
        self.rule.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'absent'):
            self.check()

    def test_exact_regular_rule_passes(self):
        self.rule.write_bytes(b'reviewed host rule\n')
        self.check()

    def test_launch_never_starts_container_when_rule_missing(self):
        args = SimpleNamespace(inputs=self.root / 'inputs.json', stage='audit', print_command=False, disposable_payload=None, attempt_label=None)
        with patch.object(launch.argparse.ArgumentParser, 'parse_args', return_value=args), \
             patch.object(launch, 'command', return_value=['docker', 'run']), \
             patch.object(launch, 'HOST_RULE', self.rule), \
             patch.object(launch.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'absent'):
                launch.main()
        run.assert_not_called()

    def test_attempt_labels_keep_default_and_stay_inside_rule_scope(self):
        self.assertEqual(launch.attempt_paths(None), (launch.STATE, launch.EVIDENCE, launch.ROOT / 'vm/vm-attempt-1-launch.log'))
        self.assertEqual(launch.attempt_paths('retry-2'), (launch.STATE / 'retry-2', launch.ROOT / 'vm/run-retry-2', launch.ROOT / 'vm/vm-retry-2-launch.log'))
        for label in ('', '../retry', 'retry/2', '-retry', 'Retry', 'a' * 33):
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, 'unsafe'):
                launch.attempt_paths(label)

    def test_disposable_source_binds_directory_and_passes_release_identity(self):
        artifact = self.root / 'artifact'
        artifact.mkdir()
        for name in ('vm', 'candidate-signed', 'dependencies-signed', 'builder', 'git-common', 'kernels'):
            (self.root / name).mkdir()
        inputs = self.root / 'inputs.json'
        inputs.write_text('{}')
        audit = self.root / 'audit.py'
        audit.write_text('fixture audit')
        audit_sha = hashlib.sha256(audit.read_bytes()).hexdigest()
        audit_report = self.root / 'vm/audit.json'
        audit_report.write_text(json.dumps({'kind': 'private-limine-export-trust-audit', 'result': 'passed',
                                           'inputs_sha256': 'd' * 64, 'audit_tool_sha256': audit_sha}))
        with tempfile.TemporaryDirectory(prefix='quattro-limine-vm-payload-20260922.', dir='/tmp') as temporary:
            source = Path(temporary) / 'fixture.zip'
            source.write_bytes(b'ZIP fixture')
            source.chmod(0o400)
            package = {'filename': source.name, 'size_bytes': source.stat().st_size,
                       'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
            report = json.dumps({'package': package}).encode()
            (artifact / 'package-evidence.json').write_bytes(report)
            (artifact / 'product.json').write_text(json.dumps({'package_filename': source.name}))
            pin = {'image_verification_sha256': hashlib.sha256(report).hexdigest(), 'generic_kernel': {'filename': 'linux.pkg.tar.xz'}}
            args = SimpleNamespace(stage='vm', inputs=inputs, inputs_sha256='d' * 64, only=None, disposable_payload=source, attempt_label='retry-2')
            with patch.multiple(launch, ROOT=self.root, ARTIFACT=artifact, AUDIT=audit, AUDIT_REPORT=audit_report,
                                AUDIT_SHA256=audit_sha, BUILDER=self.root / 'builder', KERNELS=self.root / 'kernels',
                                STATE=self.root / 'vm/state', EVIDENCE=self.root / 'vm/evidence'), \
                 patch.object(launch.admit, 'descriptor', return_value=(pin, b'')), \
                 patch.object(launch.shutil, 'disk_usage', return_value=SimpleNamespace(free=30 * 1024**3)), \
                 patch.object(launch.disposable_payload, 'filesystem', return_value='tmpfs'), \
                 patch.object(launch.disposable_payload, 'available_memory', return_value=2 * 1024**3), \
                 patch.object(launch.subprocess, 'check_output', return_value=str(self.root / 'git-common')):
                command = launch.command(args)
            self.assertIn(f'type=bind,src={source.parent},dst={source.parent}', command)
            self.assertFalse(any(part.startswith(f'type=bind,src={source},') for part in command))
            self.assertEqual(command[command.index('--payload') + 1], str(source))
            self.assertEqual(command[command.index('--state') + 1], str(self.root / 'vm/state/retry-2'))
            self.assertEqual(command[command.index('--evidence') + 1], str(self.root / 'vm/run-retry-2'))
            receipt = json.loads(command[command.index('--disposable-payload-receipt') + 1])
            self.assertEqual(receipt['file']['inode'], source.stat().st_ino)
            self.assertEqual(receipt['sha256'], package['sha256'])


if __name__ == '__main__':
    unittest.main()
