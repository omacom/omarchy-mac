import argparse
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import admit
import audit_export


class ReadOnlyAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / 'payload').mkdir()
        self.image = self.root / 'payload/root.img'
        self.image.write_bytes(b'immutable shipping root')
        record = {'members': {'root.img': {'size_bytes': self.image.stat().st_size, 'sha256': admit.digest_file(self.image)}}}
        evidence = self.root / 'package-evidence.json'
        evidence.write_text(json.dumps(record))
        self.pin = {'image_verification_sha256': admit.digest_file(evidence)}
        self.tool = self.root / 'audit.py'; self.tool.write_text('# reviewed fixture')
        self.sys = self.root / 'sys'
        (self.sys / 'loop7/loop').mkdir(parents=True)
        self.backing = self.sys / 'loop7/loop/backing_file'
        self.backing.write_text(str(self.image))
        (self.sys / 'loop7/ro').write_text('1')
        self.mount_root = self.root / 'mounts'; self.mount_root.mkdir()
        self.args = argparse.Namespace(inputs=self.root/'inputs.json', inputs_sha256='a'*64, artifact_root=self.root, audit_tool=self.tool)
        self.calls = []
        self.fail_audit = False
        self.fail_second_mount = False
        self.bad_identity = False

    def tearDown(self):
        self.temporary.cleanup()

    def run_tool(self, command, **kwargs):
        self.calls.append(command)
        if command[:2] == ['losetup', '--detach']:
            self.backing.unlink()
        if command[0] == 'mount' and self.fail_second_mount and 'subvol=@factory' in command[4]:
            raise subprocess.CalledProcessError(1, command)
        if str(self.tool) in command:
            if self.bad_identity: self.backing.write_text('/unrelated/new/image')
            if self.fail_audit: raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps({'result':'passed','trees':{'root':{},'factory':{}}}))
        return subprocess.CompletedProcess(command, 0)

    def run_audit(self):
        with patch.object(audit_export, 'SYS_BLOCK', self.sys), patch.object(audit_export, 'AUDIT_SHA256', admit.digest_file(self.tool)), \
             patch.object(audit_export.admit, 'descriptor', return_value=(self.pin,b'')), \
             patch.object(audit_export.loop_guard, 'wait', return_value={'checked':True}), \
             patch.object(audit_export.tempfile, 'mkdtemp', return_value=str(self.mount_root)), \
             patch.object(audit_export.subprocess, 'check_output', return_value='/dev/loop7\n'), \
             patch.object(audit_export.subprocess, 'run', side_effect=self.run_tool), contextlib.redirect_stdout(io.StringIO()) as output:
            audit_export.audit(self.args)
            return json.loads(output.getvalue())

    def test_audit_is_readonly_both_subvolumes_and_preserves_bytes(self):
        report = self.run_audit()
        self.assertEqual(report['root_image_sha256_before'],report['root_image_sha256_after'])
        mounts = [call for call in self.calls if call[0]=='mount']
        self.assertEqual([call[4] for call in mounts],['ro,nologreplay,subvol=@','ro,nologreplay,subvol=@factory'])
        self.assertEqual(self.calls[-1],['losetup','--detach','/dev/loop7'])
        self.assertEqual(self.image.read_bytes(),b'immutable shipping root')

    def test_failed_audit_unmounts_before_detaching(self):
        self.fail_audit=True
        with self.assertRaises(subprocess.CalledProcessError): self.run_audit()
        self.assertEqual([call[0] for call in self.calls[-3:]],['umount','umount','losetup'])
        self.assertFalse(self.mount_root.exists())

    def test_failed_second_mount_unmounts_only_first_mount(self):
        self.fail_second_mount=True
        with self.assertRaises(subprocess.CalledProcessError): self.run_audit()
        self.assertEqual([call[0] for call in self.calls[-2:]],['umount','losetup'])
        self.assertFalse(self.mount_root.exists())

    def test_changed_loop_identity_prevents_detach(self):
        self.bad_identity=True
        with self.assertRaisesRegex(ValueError,'identity changed'): self.run_audit()
        self.assertFalse(any(call[0]=='losetup' for call in self.calls))


if __name__ == '__main__':
    unittest.main()
