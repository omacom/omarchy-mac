import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
import warnings
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("admit", Path(__file__).with_name("admit.py"))
admit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admit)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.pin = {"schema": 1, "kind": "quattro-private-vm-inputs", "builder_revision": "b" * 40,
                    "runtime_revision": "c" * 40, "generic_kernel": {
                        "filename": "linux-aarch64-7.2.4-1-aarch64.pkg.tar.xz", "version": "7.2.4-1",
                        "sha256": "a" * 64, "signature_sha256": "b" * 64, "size_bytes": 100}}
        for key in ("trust_policy_sha256", "trust_public_sha256", "candidate_receipt_sha256",
                    "dependency_manifest_sha256", "image_verification_sha256", "product_sha256"):
            self.pin[key] = "a" * 64

    def tearDown(self):
        self.temporary.cleanup()

    def descriptor(self, data=None, expected=None):
        data = json.dumps(self.pin).encode() if data is None else data
        path = self.root / "inputs.json"
        path.write_bytes(data)
        return admit.descriptor(path, sha(data) if expected is None else expected)

    def make_image(self, extra=(), data=None):
        entries = [("root.img", bytes(2 * 1024 * 1024) + b"root"), ("boot.img", b"boot"),
                   ("esp/EFI/BOOT/BOOTAA64.EFI", b"efi"), ("esp/m1n1/boot.bin", b"m1n1")]
        if data is not None:
            entries = data
        entries += list(extra)
        path = self.root / "payload.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name, value in entries:
                    archive.writestr(name, value)
        record = {"schema_version": 1, "verification_kind": "asahi-full-os-package",
                  "checks": {"boot_backend": "asahi-limine"},
                  "package": {"filename": path.name, "size_bytes": path.stat().st_size, "sha256": admit.digest_file(path)},
                  "members": {(name.filename if isinstance(name, zipfile.ZipInfo) else name):
                              {"size_bytes": len(value), "sha256": sha(value)} for name, value in entries}}
        return path, record

    def extract(self, path, record):
        admit.extract_verified(path, record, self.root / "out")

    def test_descriptor_requires_independent_matching_digest(self):
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.descriptor(expected="b" * 64)

    def test_descriptor_accepts_exact_contract(self):
        self.assertEqual(self.descriptor()[0], self.pin)

    def test_descriptor_rejects_extra_fields(self):
        self.pin["allow_unsigned"] = True
        with self.assertRaisesRegex(ValueError, "fields"):
            self.descriptor()

    def test_descriptor_rejects_traversing_kernel(self):
        self.pin["generic_kernel"]["filename"] = "../linux-aarch64-7.2.4-1-aarch64.pkg.tar.xz"
        with self.assertRaisesRegex(ValueError, "filename"):
            self.descriptor()

    def test_descriptor_rejects_duplicate_json_keys(self):
        data = json.dumps(self.pin).encode().replace(b'"schema": 1', b'"schema": 1, "schema": 1')
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.descriptor(data)

    def test_copy_rejects_symlink_before_read(self):
        source = self.root / "source"
        source.symlink_to("missing")
        with self.assertRaises(OSError):
            admit.copy_pinned(source, self.root / "copy", "a" * 64)

    def test_copy_rejects_mutated_bytes(self):
        source = self.root / "source"
        source.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            admit.copy_pinned(source, self.root / "copy", sha(b"expected"))

    def test_copy_rejects_reused_destination(self):
        source = self.root / "source"
        source.write_bytes(b"ok")
        with self.assertRaises(FileExistsError):
            admit.copy_pinned(source, source, sha(b"ok"))

    def test_verified_members_extract_with_sparse_zero_ranges(self):
        path, record = self.make_image()
        self.extract(path, record)
        output = self.root / "out/root.img"
        self.assertEqual(admit.digest_file(output), record["members"]["root.img"]["sha256"])
        self.assertLess(output.stat().st_blocks * 512, output.stat().st_size)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o400)

    def test_rejects_payload_mutation(self):
        path, record = self.make_image()
        with path.open("ab") as stream:
            stream.write(b"changed")
        with self.assertRaisesRegex(ValueError, "payload checksum"):
            self.extract(path, record)

    def test_rejects_wrong_member_hash(self):
        path, record = self.make_image()
        record["members"]["root.img"]["sha256"] = "a" * 64
        with self.assertRaisesRegex(ValueError, "member checksum"):
            self.extract(path, record)

    def test_rejects_wrong_member_size(self):
        path, record = self.make_image()
        record["members"]["root.img"]["size_bytes"] -= 1
        with self.assertRaisesRegex(ValueError, "member size"):
            self.extract(path, record)

    def test_rejects_duplicate_members(self):
        path, record = self.make_image(extra=[("root.img", b"second")])
        with self.assertRaises(ValueError):
            self.extract(path, record)

    def test_rejects_unlisted_member(self):
        path, record = self.make_image(extra=[("esp/extra", b"extra")])
        del record["members"]["esp/extra"]
        with self.assertRaisesRegex(ValueError, "unexpected"):
            self.extract(path, record)

    def test_rejects_path_traversal(self):
        path, record = self.make_image(extra=[("../escape", b"bad")])
        with self.assertRaisesRegex(ValueError, "unsafe"):
            self.extract(path, record)
        self.assertFalse((self.root / "escape").exists())

    def test_rejects_symlink_member(self):
        link = zipfile.ZipInfo("esp/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        path, record = self.make_image(extra=[(link, b"/etc/passwd")])
        with self.assertRaisesRegex(ValueError, "type"):
            self.extract(path, record)

    def test_rejects_grub_profile(self):
        path, record = self.make_image()
        record["checks"]["boot_backend"] = "asahi-grub"
        with self.assertRaisesRegex(ValueError, "Limine"):
            self.extract(path, record)

    def test_reflink_rejects_symlink_export(self):
        exports = self.root / "exports"
        exports.mkdir()
        (exports / "root.img").symlink_to("elsewhere")
        with self.assertRaisesRegex(ValueError, "linked"):
            admit.clone_member(exports, Path("root.img"), self.root / "clone", {})

    def test_reflink_rejects_wrong_export_bytes(self):
        exports = self.root / "exports"
        exports.mkdir()
        (exports / "root.img").write_bytes(b"substituted")
        # Exercise the validation after FICLONE with a regular fd copy, independent of test filesystem.
        def clone(destination_fd, request, source_fd):
            self.assertEqual(request, 0x40049409)
            os.write(destination_fd, os.read(source_fd, 4096))
        with patch.object(admit.fcntl, "ioctl", clone):
            with self.assertRaisesRegex(ValueError, "checksum"):
                admit.clone_member(exports, Path("root.img"), self.root / "clone", {"size_bytes": 11, "sha256": sha(b"correct")})

    def test_reflink_keeps_source_unchanged(self):
        exports = self.root / "exports"
        exports.mkdir()
        source = exports / "root.img"
        source.write_bytes(b"correct")
        def clone(destination_fd, request, source_fd):
            os.write(destination_fd, os.read(source_fd, 4096))
        with patch.object(admit.fcntl, "ioctl", clone):
            admit.clone_member(exports, Path("root.img"), self.root / "clone", {"size_bytes": 7, "sha256": sha(b"correct")})
        self.assertEqual(source.read_bytes(), b"correct")

    def snapshot_fixture(self, source_bytes=b'authenticated archive'):
        source = self.root / 'source'
        verified = self.root / 'verified'
        source.mkdir(); verified.mkdir()
        (source / 'package.pkg.tar.zst').write_bytes(source_bytes)
        (verified / 'package.pkg.tar.zst').write_bytes(b'authenticated archive')
        return source, verified

    @staticmethod
    def fixture_clone(destination_fd, request, source_fd):
        os.write(destination_fd, os.read(source_fd, 4096))

    def test_verified_snapshot_clone_is_exclusive_and_readonly(self):
        source, verified = self.snapshot_fixture()
        target = self.root / 'snapshot'
        with patch.object(admit.fcntl, 'ioctl', self.fixture_clone):
            admit.materialize_verified_snapshot(source, verified, target)
        self.assertEqual((target / 'package.pkg.tar.zst').read_bytes(), b'authenticated archive')
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o555)
        self.assertEqual(stat.S_IMODE((target / 'package.pkg.tar.zst').stat().st_mode), 0o444)
        with self.assertRaises(FileExistsError):
            admit.materialize_verified_snapshot(source, verified, target)

    def test_verified_snapshot_rejects_source_mutation_after_verification(self):
        source, verified = self.snapshot_fixture(b'substituted after verifier')
        with patch.object(admit.fcntl, 'ioctl', self.fixture_clone):
            with self.assertRaisesRegex(ValueError, 'checksum'):
                admit.materialize_verified_snapshot(source, verified, self.root / 'snapshot')

    def test_verified_snapshot_rejects_symlink_substitution(self):
        source, verified = self.snapshot_fixture()
        (source / 'package.pkg.tar.zst').unlink()
        (source / 'package.pkg.tar.zst').symlink_to(verified / 'package.pkg.tar.zst')
        with self.assertRaisesRegex(ValueError, 'linked'):
            admit.materialize_verified_snapshot(source, verified, self.root / 'snapshot')

    def test_verified_snapshot_rejects_non_cow_fallback(self):
        source, verified = self.snapshot_fixture()
        with patch.object(admit.fcntl, 'ioctl', side_effect=OSError('cross filesystem')):
            with self.assertRaises(OSError):
                admit.materialize_verified_snapshot(source, verified, self.root / 'snapshot')

    def staged_args(self):
        for name in ('candidate-input', 'dependency-input', 'stage', 'output'):
            (self.root / name).mkdir()
        for name in ('candidate-input', 'dependency-input'):
            (self.root / name / 'package.pkg.tar.zst').write_bytes(b'authenticated archive')
        return SimpleNamespace(candidate_root=self.root / 'candidate-input',
                               dependency_root=self.root / 'dependency-input', snapshot_tmpfs=self.root / 'stage')

    @staticmethod
    def fake_snapshot_verifier(invocation, check):
        source = Path(invocation[invocation.index('--input') + 1])
        destination = Path(invocation[invocation.index('--output') + 1])
        destination.mkdir()
        (destination / 'package.pkg.tar.zst').write_bytes((source / 'package.pkg.tar.zst').read_bytes())

    def test_staged_verifiers_release_tmpfs_before_return(self):
        args = self.staged_args()
        with patch.object(admit.subprocess, 'check_output', return_value='tmpfs\n'), \
             patch.object(admit.subprocess, 'run', side_effect=self.fake_snapshot_verifier) as verifier, \
             patch.object(admit.fcntl, 'ioctl', self.fixture_clone):
            record = admit.snapshot_inputs(args, self.root / 'output', self.pin, self.root / 'builder')
        self.assertEqual(verifier.call_count, 2)
        self.assertTrue(record['tmpfs_contents_released'])
        self.assertEqual(list(args.snapshot_tmpfs.iterdir()), [])
        for kind in ('candidate', 'dependencies'):
            self.assertEqual((self.root / 'output' / kind / 'package.pkg.tar.zst').read_bytes(), b'authenticated archive')

    def test_staged_failure_releases_tmpfs_and_refuses_disk_fallback(self):
        args = self.staged_args()
        with patch.object(admit.subprocess, 'check_output', return_value='tmpfs\n'), \
             patch.object(admit.subprocess, 'run', side_effect=self.fake_snapshot_verifier), \
             patch.object(admit.fcntl, 'ioctl', side_effect=OSError('no CoW')):
            with self.assertRaisesRegex(OSError, 'no CoW'):
                admit.snapshot_inputs(args, self.root / 'output', self.pin, self.root / 'builder')
        self.assertEqual(list(args.snapshot_tmpfs.iterdir()), [])
        self.assertFalse((self.root / 'output/dependencies').exists())

    def test_staging_rejects_disk_filesystem_before_verification(self):
        args = self.staged_args()
        with patch.object(admit.subprocess, 'check_output', return_value='btrfs\n'), \
             patch.object(admit.subprocess, 'run') as verifier:
            with self.assertRaisesRegex(ValueError, 'dedicated tmpfs'):
                admit.snapshot_inputs(args, self.root / 'output', self.pin, self.root / 'builder')
        verifier.assert_not_called()

    def test_builder_uses_committed_blob_not_dirty_checkout(self):
        repo = self.root / "repo"
        (repo / "builder").mkdir(parents=True)
        for filename in ("quattro-candidate.py", "quattro-dependencies.py", "verify-asahi-os-package.py"):
            (repo / "builder" / filename).write_text("committed")
        def git(*args):
            return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL, text=True).strip()
        git("init"); git("add", "builder")
        git("-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture")
        revision = git("rev-parse", "HEAD")
        (repo / "builder/quattro-candidate.py").write_text("dirty executable substitution")
        admit.freeze_builder(repo, revision, self.root / "frozen")
        self.assertEqual((self.root / "frozen/builder/quattro-candidate.py").read_text(), "committed")
        with self.assertRaisesRegex(ValueError, "HEAD"):
            admit.freeze_builder(repo, "a" * 40, self.root / "wrong")


if __name__ == "__main__":
    unittest.main()
