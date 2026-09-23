import hashlib
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
        args = SimpleNamespace(inputs=self.root / 'inputs.json', stage='audit', print_command=False)
        with patch.object(launch.argparse.ArgumentParser, 'parse_args', return_value=args), \
             patch.object(launch, 'command', return_value=['docker', 'run']), \
             patch.object(launch, 'HOST_RULE', self.rule), \
             patch.object(launch.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'absent'):
                launch.main()
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
