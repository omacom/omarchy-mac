from pathlib import Path
import tempfile
import unittest

import loop_guard


class LoopGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.sys = self.root / 'sys'
        self.udev = self.root / 'udev'
        self.mounts = self.root / 'mountinfo'
        self.node = self.sys / 'block/loop7'
        (self.node / 'loop').mkdir(parents=True)
        (self.udev / 'data').mkdir(parents=True)
        (self.node / 'loop/backing_file').write_text('/evidence/own/root.img\n')
        (self.node / 'dev').write_text('7:7\n')
        self.properties = self.udev / 'data/b7:7'
        self.properties.write_text('E:UDISKS_IGNORE=1\nE:OMARCHY_PRIVATE_LOOP=limine-private-20260922\n')
        self.mounts.write_text('1 0 8:1 / / rw - ext4 /dev/sda1 rw\n')

    def tearDown(self):
        self.temporary.cleanup()

    def check(self, device='/dev/loop7', backing='/evidence/own/root.img'):
        return loop_guard.check(device, backing, sys_root=self.sys, udev_root=self.udev, mountinfo=self.mounts)

    def test_exact_owned_ignored_loop_is_admitted(self):
        self.assertTrue(self.check()['host_mount_absent'])

    def test_wrong_backing_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'identity'):
            self.check(backing='/evidence/other/root.img')

    def test_physical_device_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'tracked loop'):
            self.check(device='/dev/sda')

    def test_ignore_without_own_tag_is_rejected(self):
        self.properties.write_text('E:UDISKS_IGNORE=1\n')
        with self.assertRaisesRegex(ValueError, 'exclusion'):
            self.check()

    def test_own_tag_without_ignore_is_rejected(self):
        self.properties.write_text('E:OMARCHY_PRIVATE_LOOP=limine-private-20260922\n')
        with self.assertRaisesRegex(ValueError, 'exclusion'):
            self.check()

    def test_host_automount_is_rejected(self):
        self.mounts.write_text('42 1 7:7 / /run/media/user/ESP rw - vfat /dev/loop7 rw\n')
        with self.assertRaisesRegex(ValueError, 'host namespace'):
            self.check()

    def test_unavailable_host_mountinfo_fails_closed(self):
        self.mounts.unlink()
        with self.assertRaises(OSError):
            self.check()

    def test_partition_requires_its_own_ignore_property(self):
        child = self.node / 'loop7p1'
        child.mkdir()
        (child / 'dev').write_text('259:1\n')
        with self.assertRaises(OSError):
            self.check(device='/dev/loop7p1')
        (self.udev / 'data/b259:1').write_bytes(self.properties.read_bytes())
        self.assertEqual(self.check(device='/dev/loop7p1')['major_minor'], '259:1')


if __name__ == '__main__':
    unittest.main()
