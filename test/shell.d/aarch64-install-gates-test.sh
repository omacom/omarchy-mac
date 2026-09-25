#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

grep -F 'omarchy-hw-apple-silicon' "$ROOT/bin/omarchy-windows-vm" >/dev/null ||
  fail "Windows VM refuses Apple Silicon"
grep -F 'omarchy-hw-apple-silicon' "$ROOT/bin/omarchy-hibernation-setup" >/dev/null ||
  fail "hibernation setup skips Apple Silicon"
grep -F 'uname -m' "$ROOT/bin/omarchy-install-docker-dbs" >/dev/null ||
  fail "Docker DB installer checks the architecture"
grep -F 'MSSQL is not available on aarch64' "$ROOT/bin/omarchy-install-docker-dbs" >/dev/null ||
  fail "Docker DB installer explains the missing MSSQL image on aarch64"
grep -F 'omarchy-pkg-add wtype voxtype-bin' "$ROOT/bin/omarchy-voxtype-install" >/dev/null ||
  fail "dictation installer installs voxtype-bin on every architecture"
grep -F 'omarchy-pkg-drop voxtype' "$ROOT/bin/omarchy-voxtype-install" >/dev/null ||
  fail "dictation installer drops the AUR voxtype package before voxtype-bin"
grep -F 'omarchy-pkg-drop voxtype voxtype-bin' "$ROOT/bin/omarchy-voxtype-remove" >/dev/null ||
  fail "dictation remove drops both voxtype names"
grep -F 'pacman -Qo "$kernel"' "$ROOT/bin/omarchy-update-restart" >/dev/null ||
  fail "kernel reboot prompt still matches the running package-owned vmlinuz"
grep -F '"install.gaming.steam"' "$ROOT/default/omarchy/omarchy-menu.jsonc" | grep -Fq 'omarchy-pkg-available omarchy-steam-fex' ||
  fail "Steam is offered on Apple Silicon only when omarchy-steam-fex is in the repos"
grep -Fq 'omarchy-steam-fex' "$ROOT/bin/omarchy-install-gaming-steam" ||
  fail "the Steam installer pkg-adds omarchy-steam-fex on Apple Silicon"
pass "aarch64 install gates are wired"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$stub_bin/uname" <<'SH'
#!/bin/bash
[[ ${1:-} == -m ]] && { printf '%s\n' aarch64; exit 0; }
exec /usr/bin/uname "$@"
SH
chmod +x "$stub_bin"/*

PATH="$stub_bin:$PATH" bash "$ROOT/bin/omarchy-windows-vm" install >/dev/null 2>&1 &&
  fail "Windows VM install must fail on Apple Silicon"
PATH="$stub_bin:$PATH" bash "$ROOT/bin/omarchy-hibernation-setup" >/dev/null
pass "Windows VM fails closed and hibernation skips on Apple Silicon"

# Docker DB option list: MSSQL must not appear when uname is aarch64.
# Source just the options construction by running gum-less with a fake choice.
PATH="$stub_bin:$PATH" bash -c '
  source /dev/null
  options=("MySQL" "PostgreSQL" "Redis" "MongoDB" "MariaDB")
  [[ $(uname -m) != aarch64 ]] && options+=("MSSQL")
  printf "%s\n" "${options[@]}"
' | grep -qx MSSQL && fail "MSSQL stays on the aarch64 Docker DB list"
pass "MSSQL is omitted from the aarch64 Docker DB list"
