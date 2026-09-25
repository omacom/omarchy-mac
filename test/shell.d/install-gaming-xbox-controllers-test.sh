#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# xpadneo is a DKMS module, so it builds against the headers of the kernel
# actually running: linux-headers on stock Arch, linux-asahi-headers or
# linux-aurora-headers on Apple Silicon, named after the pkgbase the kernel
# package records. Headers for any other kernel would not build it.

# omarchy-pkg-kernel-headers reads only the live modules tree as root.
if (( EUID == 0 )); then
  pass "running as root, where omarchy-pkg-kernel-headers ignores fixtures; skipping the Xbox controller install"
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
calls="$test_tmp/calls"

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB

cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
printf 'omarchy-pkg-add %s\n' "$*" >>"$CALLS"
STUB

cat >"$stub_bin/uname" <<'STUB'
#!/bin/bash
if [[ ${1:-} == "-r" ]]; then
  printf '%s\n' "$KERNEL_RELEASE"
else
  exec /usr/bin/uname "$@"
fi
STUB

# The rest of the script writes under /etc and pokes the kernel; keep every
# such side effect inside the stubs. The user is already in the input group
# and xpad is not loaded, so no reboot prompt is reached.
cat >"$stub_bin/tee" <<'STUB'
#!/bin/bash
cat >/dev/null
printf 'tee %s\n' "$*" >>"$CALLS"
STUB

cat >"$stub_bin/id" <<'STUB'
#!/bin/bash
echo "wheel input"
STUB

for tool in lsmod modprobe usermod gum reboot; do
  cat >"$stub_bin/$tool" <<STUB
#!/bin/bash
printf '$tool %s\\n' "\$*" >>"\$CALLS"
STUB
done

chmod +x "$stub_bin"/*

# Each kernel as its package lays out /usr/lib/modules: the fixture name, the
# running release and the pkgbase beside its modules.
kernels=(
  "arch 6.16.8-arch1-1 linux"
  "asahi 6.17.4-asahi-1-1-ARCH linux-asahi"
  "aurora 7.1.12-2-7-ARCH linux-aurora"
)
for kernel in "${kernels[@]}"; do
  read -r fixture release pkgbase <<<"$kernel"
  mkdir -p "$test_tmp/$fixture/$release"
  printf '%s\n' "$pkgbase" >"$test_tmp/$fixture/$release/pkgbase"
done
mkdir -p "$test_tmp/unpackaged/6.16.8-custom"

in_kernel() {
  local fixture="$1" release="$2"
  shift 2
  OMARCHY_MODULES_ROOT="$test_tmp/$fixture" KERNEL_RELEASE="$release" "$@"
}

run_install() {
  : >"$calls"
  CALLS="$calls" USER="${USER:-tester}" PATH="$stub_bin:$ROOT/bin:$PATH" \
    in_kernel "$1" "$2" bash "$ROOT/bin/omarchy-install-gaming-xbox-controllers"
}

for kernel in "${kernels[@]}"; do
  read -r fixture release pkgbase <<<"$kernel"
  run_install "$fixture" "$release" >"$test_tmp/out" 2>"$test_tmp/err" ||
    fail "installing Xbox controller support on $pkgbase fails" "$(<"$test_tmp/err")"
  [[ $(grep '^omarchy-pkg-add ' "$calls") == "omarchy-pkg-add $pkgbase-headers xpadneo-dkms" ]] ||
    fail "xpadneo builds against $pkgbase-headers on $pkgbase" "$(<"$calls")"
  if grep -q 'reboot' "$calls"; then
    fail "a stubbed run reaches the reboot path"
  fi
  pass "xpadneo builds against $pkgbase-headers on $pkgbase"
done

# A kernel no package owns has no headers to install. Stop before touching
# packages or the system rather than install headers for another kernel.
if run_install unpackaged 6.16.8-custom >"$test_tmp/out" 2>"$test_tmp/err"; then
  fail "installing Xbox controller support fails for a kernel no package owns"
fi
[[ ! -s $calls ]] || fail "a kernel no package owns installs or configures nothing" "$(<"$calls")"
pass "a kernel no package owns stops the install before anything changes"

# Compare actual installer requests with the menu's availability guard. Both
# must name the same headers; a missing or wrong header cannot pass.
guard=$(node -e 'const fs=require("fs"), m=require(process.argv[1]); console.log(m.parseMenuJsonc(fs.readFileSync(process.argv[2],"utf8")).find(i=>i.id==="install.gaming.xbox-controllers").when.replace(/ && ! omarchy-pkg-present .*/,""))' "$ROOT/shell/plugins/menu/MenuModel.js" "$ROOT/default/omarchy/omarchy-menu.jsonc")
for kernel in "${kernels[@]}"; do
  read -r fixture release pkgbase <<<"$kernel"
  run_install "$fixture" "$release" >/dev/null
  selected=$(OMARCHY_PATH="$ROOT" PATH="$stub_bin:$ROOT/bin:$PATH" in_kernel "$fixture" "$release" bash -c '
    omarchy-pkg-available() { printf "%s\n" "$*"; }
    eval "$1"
  ' bash "$guard")
  grep -Fx "omarchy-pkg-add $selected" "$calls" >/dev/null ||
    fail "availability matches the installer selected targets" "$pkgbase: $selected; $(cat "$calls")"
done
pass "availability includes exactly the headers selected by the installer"
