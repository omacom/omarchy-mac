#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
source = (root / 'bin/omarchy-capture-screenrecording').read_text()
# Exercise the production function without sourcing the recorder's top-level
# dispatch. Every camera, compositor, process cleanup and mpv action is inert.
function = re.search(r'^start_webcam_overlay\(\) \{\n.*?^\}', source, re.M | re.S)
assert function
with tempfile.TemporaryDirectory() as tmp:
  tmp = Path(tmp)
  (tmp / 'overlay.sh').write_text(function[0])
  bind = tmp / 'bin'
  bind.mkdir()
  stubs = {
    'mpv': 'printf "%s\\0" "$@" >"$ARGV_FILE"',
    'v4l2-ctl': 'printf "1280x720\\n"',
    'hyprctl': 'printf \'[{"title":"WebcamOverlay"}]\\n\'',
    'omarchy-hw-apple': 'exit "$APPLE_STATUS"',
    'omarchy-capture-webcam-resize': 'printf "%s\\n" "$@" >"$RESIZE_FILE"',
    'sleep': 'exit 0',
  }
  for name, body in stubs.items():
    path = bind / name
    path.write_text('#!/bin/bash\n' + body + '\n')
    path.chmod(0o755)
  common = [
    '--profile=low-latency', '--untimed', '--no-cache',
    '--demuxer-lavf-o=video_size=1280x720,framerate=30',
    '--vf=lavfi=[crop=ih*8/9:ih]', '--title=WebcamOverlay',
    '--wayland-app-id=WebcamOverlay-medium', '--no-border', '--no-audio',
    '--no-osc', '--osd-level=0', '--really-quiet',
  ]
  for apple, renderer in ((0, ['--vo=gpu', '--gpu-api=opengl']), (1, [])):
    args = tmp / f'argv-{apple}'
    resized = tmp / f'resized-{apple}'
    env = dict(os.environ, PATH=str(bind) + ':' + os.environ['PATH'],
               ARGV_FILE=str(args), RESIZE_FILE=str(resized), APPLE_STATUS=str(apple))
    subprocess.run(['bash', '-euo', 'pipefail', '-c', '''
      source "$1/overlay.sh"
      cleanup_webcam() { :; }
      WEBCAM_DEVICE='/dev/inert camera'
      WEBCAM_SIZE=medium
      REGION_FILE="$1/region"
      start_webcam_overlay 'region:800x600+10+20'
      wait
    ''', 'webcam-fixture', str(tmp)], env=env, check=True)
    actual = args.read_bytes().decode().split('\0')[:-1]
    assert actual == ['av://v4l2:/dev/inert camera'] + renderer + common, actual
    assert resized.read_text() == 'medium\n'
    assert (tmp / 'region').read_text() == '800x600+10+20\n'
print('ok - Apple webcam selects the older OpenGL renderer; other platforms preserve mpv defaults')
PY
