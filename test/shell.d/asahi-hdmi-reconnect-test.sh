#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command python3

python3 - "$ROOT" <<'PY'
from pathlib import Path
import hashlib
import subprocess
import sys
root = Path(sys.argv[1])
patches = root / 'patches/asahi'
patch = patches / 'apple-dcp-hdmi-reconnect.patch'
assert hashlib.sha256(patch.read_bytes()).hexdigest() == 'dbf332ead80ad84d5fb681fe83fc92c89cb88e0d4e416142acbb80565aacedcf', 'Hardware-tested patch changed; refresh evidence deliberately'
build = (patches / 'build-hdmi-reconnect.sh').read_text()
recipe = (patches / 'PKGBUILD').read_text()
assert 'ce9f2eba72c061a50b2d790450e90af3439d8c24' in build
assert 'git -C "$source_dir" apply --check' in build
assert build.index('apply --check') < build.index('apply "$here/')
assert 'LOCALVERSION_AUTO' in build and '--file "$source_dir/.config"' in build
assert 'LOCALVERSION= Image modules dtbs' in build
assert '7.1.13-1-1-ARCH-hdmi-recover' in build and '7.1.13-1-1-ARCH-hdmi-recover' in recipe
assert 'pkgname=linux-asahi-hdmi-recover' in recipe
assert 'ASAHI_KERNEL_SOURCE:?' in recipe
assert 'arch/arm64/boot/dts/apple/*.dtb' in recipe
assert 'INSTALL_MOD_PATH="$pkgdir/usr"' in recipe
assert 'provides=' not in recipe and 'conflicts=' not in recipe and 'replaces=' not in recipe
assert 'pacman -' not in build and 'grub-' not in build and 'makepkg -i' not in build
assert 'validate-package.py' in build
subprocess.run(['bash', '-n', str(patches / 'build-hdmi-reconnect.sh'), str(patches / 'PKGBUILD')], check=True)
# Argument validation must fail before any source/build/host mutation.
result = subprocess.run(['bash', str(patches / 'build-hdmi-reconnect.sh')], capture_output=True, text=True)
assert result.returncode == 2 and 'Usage:' in result.stderr
print('ok - exact hardware patch, opt-in build/package contracts, and argument rejection')
PY
