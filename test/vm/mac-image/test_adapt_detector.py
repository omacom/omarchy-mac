import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import adapt_detector as detector


class DetectorAdaptationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / 'root'
        (self.root / 'usr/bin').mkdir(parents=True)
        (self.root / 'usr/share/omarchy/bin').mkdir(parents=True)
        self.target = self.root / 'usr/bin' / detector.NAME
        self.target.write_bytes(b'#!/bin/bash\nexit 1\n')
        self.target.chmod(0o755)
        self.link = self.root / 'usr/share/omarchy/bin' / detector.NAME
        self.link.symlink_to(detector.TARGET)

    def tearDown(self):
        self.temporary.cleanup()

    def test_absolute_symlink_is_preserved_and_only_guest_realfile_opened(self):
        self.assertNotEqual(self.link.resolve(), self.target)
        with patch.object(detector.os, 'open', wraps=os.open) as opened:
            result = detector.adapt(self.root)
        opened.assert_called_once_with(self.target, os.O_RDWR | os.O_NOFOLLOW)
        self.assertEqual(self.target.read_bytes(), detector.OVERRIDE)
        self.assertEqual(os.readlink(self.link), detector.TARGET)
        self.assertEqual(result['modified_file'], str(self.target))
        self.assertEqual(result['mode_preserved'], 0o755)
        self.assertNotEqual(result['sha256_before'], result['sha256_after'])

    def test_changed_compatibility_link_refuses_without_write(self):
        before = self.target.read_bytes()
        self.link.unlink()
        self.link.symlink_to('/etc/passwd')
        with self.assertRaisesRegex(ValueError, 'target differs'):
            detector.adapt(self.root)
        self.assertEqual(self.target.read_bytes(), before)

    def test_regular_compatibility_leaf_refuses(self):
        self.link.unlink()
        self.link.write_text('unexpected regular command')
        with self.assertRaisesRegex(ValueError, 'target differs'):
            detector.adapt(self.root)

    def test_escaped_bin_parent_refuses_and_preserves_external_file(self):
        external = self.root.parent / 'external-bin'
        (self.root / 'usr/bin').rename(external)
        (self.root / 'usr/bin').symlink_to(external)
        before = (external / detector.NAME).read_bytes()
        with self.assertRaisesRegex(ValueError, 'detector parent'):
            detector.adapt(self.root)
        self.assertEqual((external / detector.NAME).read_bytes(), before)

    def test_linked_real_target_refuses(self):
        external = self.root.parent / 'external-command'
        self.target.rename(external)
        self.target.symlink_to(external)
        with self.assertRaisesRegex(ValueError, 'regular executable'):
            detector.adapt(self.root)
        self.assertEqual(external.read_bytes(), b'#!/bin/bash\nexit 1\n')

    def test_linked_root_refuses(self):
        alias = self.root.parent / 'alias'
        alias.symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'unsafe disposable root'):
            detector.adapt(alias)


if __name__ == '__main__':
    unittest.main()
