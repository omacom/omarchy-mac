import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import disposable_payload as payload


def digest(data):
    return hashlib.sha256(data).hexdigest()


class DisposablePayloadTests(unittest.TestCase):
    def setUp(self):
        self.stage = tempfile.TemporaryDirectory(prefix='quattro-limine-vm-payload-20260922.', dir='/tmp')
        self.records = tempfile.TemporaryDirectory(prefix='quattro-disposable-records-', dir='/tmp')
        self.path = Path(self.stage.name) / 'omarchy-test.zip'
        self.path.write_bytes(b'archive fixture\n' * 8192)
        self.path.chmod(0o400)
        self.admitted = Path(self.records.name)
        self.package = {'filename': self.path.name, 'size_bytes': self.path.stat().st_size,
                        'sha256': digest(self.path.read_bytes())}
        report = json.dumps({'package': self.package}).encode()
        (self.admitted / 'verification.json').write_bytes(report)
        pin = {'schema': 1, 'kind': 'quattro-private-vm-inputs', 'builder_revision': 'b' * 40,
               'runtime_revision': 'c' * 40, 'trust_policy_sha256': 'a' * 64, 'trust_public_sha256': 'a' * 64,
               'candidate_receipt_sha256': 'a' * 64, 'dependency_manifest_sha256': 'a' * 64,
               'image_verification_sha256': digest(report), 'product_sha256': 'a' * 64,
               'generic_kernel': {'filename': 'linux-aarch64-7.2.4-1-aarch64.pkg.tar.xz', 'version': '7.2.4-1',
                                  'sha256': 'a' * 64, 'signature_sha256': 'b' * 64, 'size_bytes': 100}}
        raw = json.dumps(pin).encode()
        (self.admitted / 'inputs.json').write_bytes(raw)
        self.inputs_sha = digest(raw)
        (self.admitted / 'admission.json').write_text(json.dumps({'inputs_sha256': self.inputs_sha, 'payload_sha256': self.package['sha256']}))
        self.receipt = payload.inspect(self.path, self.package, self.inputs_sha, os.getuid())

    def tearDown(self):
        self.stage.cleanup()
        self.records.cleanup()

    def release(self):
        return payload.release(self.receipt, self.admitted)

    def test_real_tmpfs_lease_unlink_releases_allocation(self):
        result = self.release()
        self.assertEqual(result['result'], 'passed')
        self.assertTrue(result['write_lease_checked'])
        self.assertGreater(result['allocated_bytes_released'], 0)
        self.assertFalse(self.path.exists())
        self.assertEqual(list(self.path.parent.iterdir()), [])

    def test_other_open_description_refuses_without_unlink(self):
        with self.path.open('rb'):
            with self.assertRaises(BlockingIOError):
                self.release()
        self.assertTrue(self.path.is_file())

    def test_hardlink_refuses_without_unlink(self):
        os.link(self.path, self.admitted / 'held-link')
        with self.assertRaisesRegex(ValueError, 'link count'):
            self.release()
        self.assertTrue(self.path.is_file())

    def test_inode_substitution_refuses_even_when_bytes_match(self):
        replacement = self.admitted / 'replacement'
        replacement.write_bytes(self.path.read_bytes())
        replacement.chmod(0o400)
        os.replace(replacement, self.path)
        with self.assertRaisesRegex(ValueError, 'identity'):
            self.release()
        self.assertTrue(self.path.is_file())

    def test_same_inode_content_change_refuses_without_unlink(self):
        self.path.chmod(0o600)
        self.path.write_bytes(b'x' * self.package['size_bytes'])
        self.path.chmod(0o400)
        with self.assertRaisesRegex(ValueError, 'changed after admission'):
            self.release()
        self.assertTrue(self.path.is_file())

    def test_owner_substitution_refuses(self):
        self.receipt['file']['uid'] += 1
        with self.assertRaisesRegex(ValueError, 'ownership'):
            self.release()

    def test_missing_success_receipt_refuses(self):
        (self.admitted / 'admission.json').unlink()
        with self.assertRaises(FileNotFoundError):
            self.release()
        self.assertTrue(self.path.is_file())

    def test_symlink_source_refuses(self):
        source = self.admitted / 'original'
        self.path.rename(source)
        self.path.symlink_to(source)
        with self.assertRaisesRegex(ValueError, 'linked'):
            payload.inspect(self.path, self.package, self.inputs_sha, os.getuid())

    def test_directory_with_extra_file_refuses(self):
        (self.path.parent / 'unrelated').write_text('preserve')
        with self.assertRaisesRegex(ValueError, 'only its ZIP'):
            self.release()

    def test_non_tmpfs_refuses(self):
        with patch.object(payload, 'filesystem', return_value='btrfs'):
            with self.assertRaisesRegex(ValueError, 'tmpfs'):
                self.release()

    def test_group_accessible_directory_refuses_inspection(self):
        self.path.parent.chmod(0o750)
        with self.assertRaisesRegex(ValueError, 'ownership or mode'):
            payload.inspect(self.path, self.package, self.inputs_sha, os.getuid())

    def test_file_bind_mount_refuses(self):
        mounts = self.admitted / 'mountinfo'
        mounts.write_text(f'1 2 0:1 / {self.path} ro - tmpfs tmpfs ro\n')
        with self.assertRaisesRegex(ValueError, 'retained'):
            payload.reject_file_mounts(self.path, mounts)

    def test_retained_allocation_refuses_guest_progress(self):
        with patch.object(payload, 'free_bytes', return_value=100), patch.object(payload.time, 'monotonic', side_effect=[0, 3]):
            with self.assertRaisesRegex(ValueError, 'allocation retained'):
                self.release()
        self.assertFalse(self.path.exists())

    def test_memory_budget_is_checked_before_admission(self):
        with patch.object(payload, 'available_memory', return_value=1024):
            with self.assertRaisesRegex(ValueError, 'available memory'):
                payload.require_memory(self.path.parent, self.path.parent)


if __name__ == '__main__':
    unittest.main()
