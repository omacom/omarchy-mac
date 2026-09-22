import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
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
