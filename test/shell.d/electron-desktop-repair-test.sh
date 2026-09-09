#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
export ROOT
python3 - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(os.environ['ROOT'])
with tempfile.TemporaryDirectory() as tmp:
  tmp = Path(tmp)
  home = tmp / 'home'
  bind = tmp / 'bin'
  bind.mkdir()
  home.mkdir()
  real = tmp / 'real app'
  real.write_text('#!/bin/bash\nexit 0\n')
  real.chmod(0o755)
  compatible = tmp / 'compatible'
  compatible.write_text('apple,j613')
  vendor = tmp / 'vendor.desktop'
  original = f'''# user comment
[Desktop Entry]
Name=My profile
Exec="{real}" --profile-directory="Profile 2" %U
TryExec="{real}"
[Desktop Action private]
Exec={real.as_posix().replace(' ', '-')} --incognito %U
[Desktop Action custom]
Exec=env SPECIAL=yes chromium %U
'''
  vendor.write_text(original)
  env = dict(os.environ, HOME=str(home), OMARCHY_PATH=str(root), PATH=f'{bind}:{root}/bin:' + os.environ['PATH'],
             OMARCHY_ELECTRON_GL_BIND_DIR=str(bind), OMARCHY_CHROMIUM_BIN=str(real),
             OMARCHY_CHROMIUM_DESKTOP=str(vendor), OMARCHY_1PASSWORD_BIN='/absent',
             OMARCHY_DEVICE_TREE_COMPATIBLE=str(compatible), OMARCHY_DRI_PATH=str(tmp / 'dri'))
  sentinel = tmp / 'forbidden'
  for name in ('sudo', 'pkexec', 'curl'):
    path = bind / name
    path.write_text(f'#!/bin/bash\ntouch "{sentinel}"\nexit 91\n')
    path.chmod(0o755)
  def run(args, status=0):
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    assert result.returncode == status, (args, result.returncode, result.stderr)
    return result
  wrap = str(root / 'bin/omarchy-cmd-electron-gl-wrap')
  leaf = 'source "$OMARCHY_PATH/install/user/hardware/apple/electron-gl.sh"'
  system = 'source "$OMARCHY_PATH/install/hardware/apple/electron-gl.sh"'
  run([wrap, '--check', 'chromium', str(real)], 4)
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert not sentinel.exists() and not (bind / 'chromium').exists()
  run(['bash', '-euo', 'pipefail', '-c', system])
  run([wrap, '--check', 'chromium', str(real)])
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  desktop = home / '.local/share/applications/chromium.desktop'
  expected = original.replace(f'"{real}"', f'"{bind}/chromium"')
  assert desktop.read_text() == expected
  desktop.write_text(original + '# extra customization\n')
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert desktop.read_text() == expected + '# extra customization\n'
  backups = list(desktop.parent.glob('chromium.desktop.bak.*'))
  assert len(backups) == 1 and backups[0].read_text() == original + '# extra customization\n'
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert list(desktop.parent.glob('chromium.desktop.bak.*')) == backups
  desktop.unlink()
  desktop.symlink_to(vendor)
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert desktop.is_symlink() and vendor.read_text() == original
  (bind / 'chromium').write_text('#!/bin/bash\n# administrator launcher\n')
  run([wrap, 'chromium', str(real)], 3)
  run(['bash', '-euo', 'pipefail', '-c', system])
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  for migration in ('1788639443.sh', '1788980682.sh'):
    run(['bash', '-euo', 'pipefail', str(root / 'migrations' / migration)])
  assert not sentinel.exists()
  # Operational failures are not ownership conflicts and must stop the leaf.
  (bind / 'chromium').unlink()
  failure = bind / 'mktemp'
  failure.write_text('#!/bin/bash\nexit 93\n')
  failure.chmod(0o755)
  run(['bash', '-euo', 'pipefail', '-c', system], 93)
  failure.unlink()
  # Existing 1Password repair never downloads or executes a custom launcher.
  install = tmp / '1Password'
  install.mkdir()
  executable = install / '1password'
  executable.write_bytes(real.read_bytes())
  executable.chmod(0o755)
  (bind / '1password').write_text('# custom launcher\n')
  env.update(OMARCHY_1PASSWORD_INSTALL_DIR=str(install), OMARCHY_1PASSWORD_BIN_LINK=str(bind / '1password'))
  run([str(root / 'bin/omarchy-install-1password')])
  assert not sentinel.exists()
print('ok - Electron ownership, user privilege boundary, preserving desktop repair and migration regressions')
PY
