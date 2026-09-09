#!/bin/bash
# Checks that the repo's Asahi/aarch64 defaults are in place: ARM mirrors, the
# Asahi Alarm repo, and an installer that targets aarch64.
#
# Most of what this asserts is repo content, which is checkable anywhere, so the
# suite runs on a development machine as well as on the Mac. The two checks that
# genuinely need Apple Silicon -- the architecture itself and the device tree --
# report and are skipped elsewhere rather than failing, so this is not a suite
# that can only ever pass on one machine.

set -euo pipefail

# From the file, not $OMARCHY_PATH or $PWD: the session exports OMARCHY_PATH for
# the installed Omarchy, so honouring it here tests a different checkout than
# the one these tests live in.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OMARCHY_INSTALL="$ROOT/install"

pass() { echo "✓ $*"; }
skip() { echo "- $* (skipped)"; }
fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "=== Asahi Linux compatibility ==="
echo "Repo: $ROOT"
echo "Architecture: $(uname -m)"
echo "Kernel: $(uname -r)"

echo
echo "=== Hardware, where there is any ==="

if [[ $(uname -m) == "aarch64" ]]; then
  pass "running on aarch64"
  if [[ -f /proc/device-tree/compatible ]]; then
    if grep -q apple /proc/device-tree/compatible 2>/dev/null; then
      pass "Apple hardware in the device tree"
    else
      pass "device tree present, not Apple (aarch64 VM or other board)"
    fi
  else
    pass "no device tree (container or VM)"
  fi
else
  skip "not aarch64, so the hardware checks say nothing here"
fi

echo
echo "=== Mirror defaults ==="

[[ -f "$ROOT/fix-mirrors.sh" ]] || fail "fix-mirrors.sh is missing"
bash -n "$ROOT/fix-mirrors.sh" || fail "fix-mirrors.sh does not parse"
pass "fix-mirrors.sh is present and parses"

grep -q "mirror.archlinuxarm.org" "$ROOT/default/pacman/aarch64/mirrorlist" ||
  fail "the aarch64 mirrorlist has no Arch Linux ARM mirror"
pass "the aarch64 mirrorlist points at Arch Linux ARM"

grep -q 'github.com/asahi-alarm/asahi-alarm/releases/download/\$arch' \
  "$ROOT/default/pacman/aarch64/mirrorlist.asahi-alarm" ||
  fail "the Asahi Alarm mirrorlist has no \$arch release URL"
pass "the Asahi Alarm mirrorlist keeps its \$arch release URL"

echo
echo "=== Installer defaults ==="

# arm-mirrors.sh is where the aarch64 mirror handling lives; the older layout
# this suite was written against kept it in a preflight guard.sh that no longer
# exists.
arm_mirrors="$OMARCHY_INSTALL/preflight/arm-mirrors.sh"
[[ -f $arm_mirrors ]] || fail "install/preflight/arm-mirrors.sh is missing"
grep -qE 'aarch64|arm64' "$arm_mirrors" ||
  fail "arm-mirrors.sh does not mention aarch64"
pass "the installer's ARM mirror step targets aarch64"

conf="$ROOT/default/pacman/aarch64/pacman.conf"
[[ -f $conf ]] || fail "default/pacman/aarch64/pacman.conf is missing"
grep -q "^Architecture = aarch64" "$conf" ||
  fail "aarch64 pacman.conf does not set Architecture = aarch64"
grep -q "^\[asahi-alarm\]" "$conf" ||
  fail "aarch64 pacman.conf does not offer the asahi-alarm repo"
pass "the shipped aarch64 pacman.conf targets Asahi Alarm"

echo
echo "=== All Asahi compatibility checks passed ==="
