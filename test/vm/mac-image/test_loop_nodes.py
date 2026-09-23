import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import loop_nodes as nodes


class FakeNodes:
    def __init__(self):
        self.files = {}
        self.created = []
        self.removed = []

    def lstat(self, path):
        if str(path) not in self.files:
            raise FileNotFoundError(path)
        return self.files[str(path)]

    def create(self, path, mode, rdev):
        if str(path) in self.files:
            raise FileExistsError(path)
        self.files[str(path)] = SimpleNamespace(st_mode=mode, st_rdev=rdev, st_dev=100, st_ino=1000 + len(self.files))
        self.created.append(str(path))

    def unlink(self, path):
        del self.files[str(path)]
        self.removed.append(str(path))


class LoopNodeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.namespace = self.root / 'namespace-mountinfo'
        self.host = self.root / 'host-mountinfo'
        self.namespace.write_text('1 2 0:400 / /dev rw - tmpfs tmpfs rw\n')
        self.host.write_text('1 2 0:5 / /dev rw - devtmpfs devtmpfs rw\n')
        self.parent = self.root / 'sys/block/loop7'
        (self.parent / 'loop').mkdir(parents=True)
        (self.parent / 'loop/backing_file').write_text('/owned/plain.img')
        for number in (1, 2):
            child = self.parent / f'loop7p{number}'
            child.mkdir()
            (child / 'partition').write_text(str(number))
            (child / 'dev').write_text(f'259:{19 + number}')
        self.records = [{'path': '/dev/loop7p1', 'major_minor': '259:20'}, {'path': '/dev/loop7p2', 'major_minor': '259:21'}]
        self.fake = FakeNodes()

    def tearDown(self):
        self.temporary.cleanup()

    def private(self):
        return nodes.private_dev(self.namespace, self.host)

    def check(self, device, backing):
        self.assertEqual(backing, '/owned/plain.img')
        return {'major_minor': '7:7' if device == '/dev/loop7' else (self.parent / Path(device).name / 'dev').read_text()}

    def discover(self, count=2, device='/dev/loop7', backing='/owned/plain.img', check=None):
        return nodes.discovered(device, backing, count, sys_root=self.root / 'sys', check=check or self.check)

    def test_container_private_dev_accepted(self):
        self.assertEqual(self.private()['device'], '0:400')

    def test_host_dev_bind_refused(self):
        self.namespace.write_text('1 2 0:5 / /dev rw - tmpfs tmpfs rw\n')
        with self.assertRaisesRegex(ValueError, 'private'):
            self.private()

    def test_non_tmpfs_dev_refused(self):
        self.namespace.write_text('1 2 0:400 / /dev rw - devtmpfs devtmpfs rw\n')
        with self.assertRaisesRegex(ValueError, 'private'):
            self.private()

    def test_missing_host_mount_visibility_refused(self):
        self.host.write_text('')
        with self.assertRaisesRegex(ValueError, 'visibility'):
            self.private()

    def test_only_exact_guarded_partition_inventory_accepted(self):
        self.assertEqual(self.discover(), self.records)
        with self.assertRaisesRegex(ValueError, 'inventory'):
            self.discover(count=3)

    def test_physical_disk_refused(self):
        with self.assertRaisesRegex(ValueError, 'exact owned loop'):
            self.discover(device='/dev/nvme0n1')

    def test_changed_backing_refused(self):
        (self.parent / 'loop/backing_file').write_text('/unrelated.img')
        with self.assertRaisesRegex(ValueError, 'backing changed'):
            self.discover()

    def test_wrong_partition_number_refused(self):
        (self.parent / 'loop7p1/partition').write_text('2')
        with self.assertRaisesRegex(ValueError, 'identity differs'):
            self.discover()

    def test_host_guard_failure_prevents_discovery(self):
        def rejected(device, backing):
            raise ValueError('host guard rejected')
        with self.assertRaisesRegex(ValueError, 'host guard'):
            self.discover(check=rejected)

    def test_missing_nodes_created_mode_0600_and_cleaned(self):
        created = []
        nodes.ensure(self.records, created, nodes=self.fake)
        self.assertEqual(self.fake.created, ['/dev/loop7p1', '/dev/loop7p2'])
        self.assertEqual([item['mode'] for item in created], [0o600, 0o600])
        self.assertEqual([item['rdev'] for item in created], [os.makedev(259, 20), os.makedev(259, 21)])
        nodes.remove_created(created, nodes=self.fake)
        self.assertEqual(len(self.fake.removed), 2)

    def test_correct_existing_node_is_preserved(self):
        self.fake.create(Path('/dev/loop7p1'), stat.S_IFBLK | 0o660, os.makedev(259, 20))
        created = []
        nodes.ensure(self.records[:1], created, nodes=self.fake)
        self.assertEqual(created, [])
        nodes.remove_created(created, nodes=self.fake)
        self.assertIn('/dev/loop7p1', self.fake.files)

    def test_wrong_device_node_refused_without_replacement(self):
        self.fake.create(Path('/dev/loop7p1'), stat.S_IFBLK | 0o600, os.makedev(259, 99))
        with self.assertRaisesRegex(ValueError, 'wrong major/minor'):
            nodes.ensure(self.records, [], nodes=self.fake)
        self.assertEqual(self.fake.removed, [])

    def test_symlink_or_regular_node_refused(self):
        for kind in (stat.S_IFLNK, stat.S_IFREG):
            self.fake.files['/dev/loop7p1'] = SimpleNamespace(st_mode=kind | 0o600, st_rdev=os.makedev(259, 20), st_dev=100, st_ino=1000)
            with self.assertRaisesRegex(ValueError, 'non-block'):
                nodes.ensure(self.records, [], nodes=self.fake)

    def test_replaced_created_node_refuses_cleanup(self):
        created = []
        nodes.ensure(self.records[:1], created, nodes=self.fake)
        self.fake.files['/dev/loop7p1'].st_ino += 1
        with self.assertRaisesRegex(ValueError, 'identity changed'):
            nodes.remove_created(created, nodes=self.fake)
        self.assertEqual(self.fake.removed, [])

    def test_partial_creation_receipt_survives_failure(self):
        receipt = self.root / 'receipt.json'
        def partial(records, created):
            created.append({'path': '/dev/loop7p1', 'inode': 1000})
            raise ValueError('second node failed')
        with patch.object(nodes, 'private_dev', return_value={'device': '0:400'}), \
             patch.object(nodes, 'discovered', return_value=self.records), patch.object(nodes, 'ensure', side_effect=partial):
            with self.assertRaisesRegex(ValueError, 'second node'):
                nodes.create('/dev/loop7', '/owned/plain.img', 2, receipt)
        data = json.loads(receipt.read_text())
        self.assertEqual(data['result'], 'failed')
        self.assertEqual(len(data['created']), 1)


if __name__ == '__main__':
    unittest.main()
