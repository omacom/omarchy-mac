import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import verify_generic_kernel as verifier


class GenericKernelKeyringTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.evidence = self.root / ('long-evidence-' * 10)
        self.evidence.mkdir()
        self.invocations = []

    def tearDown(self):
        self.temporary.cleanup()

    def execute(self, failure=None):
        def run(command, **kwargs):
            self.invocations.append(command)
            home = Path(command[command.index('--homedir') + 1])
            self.assertEqual(home.parent, Path('/tmp'))
            self.assertTrue(home.name.startswith('omarchy-vm-gpg-'))
            self.assertEqual(stat.S_IMODE(home.stat().st_mode), 0o700)
            self.assertLess(len(str(home / 'S.gpg-agent.browser').encode()), 108)
            if failure in command:
                raise subprocess.CalledProcessError(2, command)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(verifier.subprocess, 'run', side_effect=run):
            verifier.verify(self.root / 'vendor.gpg', self.root / 'kernel.pkg.tar.xz', self.root / 'kernel.pkg.tar.xz.sig', self.evidence)

    def assert_clean(self, result):
        record = json.loads((self.evidence / 'kernel-keyring-home.json').read_text())
        self.assertEqual(record['result'], result)
        self.assertTrue(record['owned_home_removed'])
        self.assertFalse(Path(record['home']).exists())
        self.assertLess(record['maximum_socket_path_bytes'], 108)
        self.assertIn('gpg-agent', self.invocations[-1])
        homes = {command[command.index('--homedir') + 1] for command in self.invocations}
        self.assertEqual(len(homes), 1)
        return record

    def test_short_owned_home_and_agent_cleaned_after_verification(self):
        self.execute()
        record = self.assert_clean('passed')
        self.assertTrue(record['owned_agent_stopped'])
        self.assertTrue(record['signature_verified'])
        verify = self.invocations[1]
        self.assertIn('--no-auto-key-retrieve', verify)
        self.assertEqual(verify[-2:], [str(self.root / 'kernel.pkg.tar.xz.sig'), str(self.root / 'kernel.pkg.tar.xz')])

    def test_import_failure_still_stops_agent_and_removes_home(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute('--import')
        self.assert_clean('failed')
        self.assertEqual(len(self.invocations), 2)

    def test_signature_failure_still_stops_agent_and_removes_home(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute('--verify')
        self.assert_clean('failed')

    def test_cleanup_failure_is_not_reported_as_passed(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute('gpg-agent')
        record = self.assert_clean('failed')
        self.assertNotIn('owned_agent_stopped', record)


if __name__ == '__main__':
    unittest.main()
