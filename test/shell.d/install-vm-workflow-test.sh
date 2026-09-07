#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
require_command python3

python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import yaml

root = Path(sys.argv[1])
workflow = yaml.load((root / '.github/workflows/install-vm.yml').read_text(), Loader=yaml.BaseLoader)
events = workflow['on']
assert set(events) == {'pull_request', 'push', 'workflow_dispatch', 'schedule'}
assert not events['pull_request'], 'PR coverage must have no branch, path, or type filters'
assert events['push'] == {'branches': ['quattro']}
assert events['schedule'], 'retain scheduled coverage'
job = workflow['jobs']['install']
assert 'if' not in job, 'every PR must reach the install job'
assert job['runs-on'] == 'ubuntu-24.04-arm', 'untrusted code needs a disposable hosted runner'
assert workflow['permissions'] == {'contents': 'read'}
assert 'permissions' not in job and 'secrets.' not in str(workflow)
assert 'github.event.pull_request.number || github.ref' in workflow['concurrency']['group']
assert workflow['concurrency']['cancel-in-progress'] == 'true'
checkout = next(step for step in job['steps'] if step.get('uses', '').startswith('actions/checkout@'))
assert checkout['with'] == {'persist-credentials': 'false'}, 'use the default merge ref without stored credentials'
assert not any('actions/cache@' in step.get('uses', '') for step in job['steps'])
assert not (root / '.github/workflows/install-vm-selective-edge.yml').exists()
install_step = next(step for step in job['steps'] if 'bash ./test/vm/run-selective-edge' in step.get('run', ''))
install_env = {**job['env'], **install_step.get('env', {})}
for key in ('OMARCHY_INSTALL_VM_PACKAGE_SOURCES', 'OMARCHY_INSTALL_VM_IDEMPOTENCY'):
    assert install_env[key] == '1', f'{key} must be enabled'
for key in ('OMARCHY_INSTALL_VM_WORK', 'OMARCHY_INSTALL_VM_CACHE'):
    assert 'github.run_id' in install_env[key] and 'github.run_attempt' in install_env[key]
print('ok - every PR gets isolated ARM install coverage with both validation modes')

run = install_step['run']
preserved = re.search(r'--preserve-env=([^\s]+)', run).group(1).split(',')
assert set(install_env).issubset(preserved), 'sudo must preserve work, cache, and validation flags'
# Execute the real workflow command with a fake harness, including its log reset.
# Both success and failure must survive the tee pipeline and retain full output.
with tempfile.TemporaryDirectory() as temp:
    cwd = Path(temp)
    (cwd / 'test/vm').mkdir(parents=True)
    (cwd / 'bin').mkdir()
    (cwd / 'bin/sudo').write_text('#!/bin/bash\nshift\nexec "$@"\n')
    (cwd / 'bin/sudo').chmod(0o755)
    (cwd / 'test/vm/run-selective-edge').write_text('''#!/bin/bash
[[ $OMARCHY_INSTALL_VM_PACKAGE_SOURCES == 1 && $OMARCHY_INSTALL_VM_IDEMPOTENCY == 1 ]] || exit 99
rm -rf "$OMARCHY_INSTALL_VM_WORK/logs"
mkdir -p "$OMARCHY_INSTALL_VM_WORK/logs"
echo 'harness output before exit'
exit "$HARNESS_EXIT"
''')
    env = {**os.environ, **install_env, 'PATH': f'{cwd}/bin:' + os.environ['PATH'],
           'OMARCHY_INSTALL_VM_WORK': str(cwd / 'work'), 'OMARCHY_INSTALL_VM_CACHE': str(cwd / 'cache'),
           'RUNNER_TEMP': str(cwd), 'GITHUB_STEP_SUMMARY': str(cwd / 'summary')}
    for status in (0, 17):
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', run], cwd=cwd,
                                env={**env, 'HARNESS_EXIT': str(status)}, capture_output=True, text=True)
        assert result.returncode == status, result.stdout + result.stderr
        logs = cwd / 'work/logs'
        assert (logs / 'exit_code').read_text().strip() == str(status)
        assert 'harness output before exit' in (logs / 'harness.log').read_text()
print('ok - workflow preserves harness failures and complete logs through guest log cleanup')
PY
