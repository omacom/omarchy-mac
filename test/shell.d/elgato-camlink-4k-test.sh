#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The Cam Link relay builds v4l2loopback with DKMS, so the kernels it may boot
# need their headers: on x86 every installed kernel Omarchy knows by name, on
# Apple Silicon the running kernel's, named after the pkgbase its package
# records.

require_platform_fixtures "the Cam Link install"

leaf="$ROOT/install/hardware/fix-elgato-camlink-4k.sh"
migration=$(grep -l "fix-elgato-camlink-4k.sh" "$ROOT"/migrations/*.sh | head -1)
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-hw-elgato-camlink-4k" <<'STUB'
#!/bin/bash
[[ ${CAMLINK:-1} == 1 ]]
STUB

cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
[[ $1 == -Qqs ]] || exit 1
tr ' ' '\n' <<<"$INSTALLED" | grep -Ei -- "$2"
STUB

cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
printf 'omarchy-pkg-add %s\n' "$*" >>"$CALLS"
STUB

# The rest of the leaf writes under /etc; record it instead.
cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$CALLS"
[[ $1 != tee ]] || cat >/dev/null
STUB

# Stands in for fake_platform's uname, which cannot fake the kernel release;
# only its proc trees are used below.
cat >"$stub_bin/uname" <<'STUB'
#!/bin/bash
case ${1:-} in
  -r) printf '%s\n' "$KERNEL_RELEASE" ;;
  -m) printf '%s\n' "$MACHINE" ;;
  *) exec /usr/bin/uname "$@" ;;
esac
STUB

chmod +x "$stub_bin"/*

fake_platform "$test_tmp/x86" generic
fake_platform "$test_tmp/apple" apple-silicon

# $1 names a modules tree; each further pair is a kernel release and the
# pkgbase its package writes there.
fake_modules() {
  local tree="$test_tmp/$1"
  shift
  mkdir -p "$tree"
  while (( $# > 0 )); do
    mkdir -p "$tree/$1"
    printf '%s\n' "$2" >"$tree/$1/pkgbase"
    shift 2
  done
}

# Runs a command on a platform (x86 or apple), with a modules tree, a running
# release and the installed packages pacman's search sees.
on_machine() {
  local platform="$1" tree="$2" release="$3" installed="$4" machine=x86_64
  shift 4

  [[ $platform == x86 ]] || machine=aarch64
  : >"$calls"
  CALLS="$calls" OMARCHY_PATH="$ROOT" OMARCHY_PROC_ROOT="$test_tmp/$platform/proc" MACHINE="$machine" \
    OMARCHY_MODULES_ROOT="$test_tmp/$tree" KERNEL_RELEASE="$release" INSTALLED="$installed" \
    PATH="$stub_bin:$ROOT/bin:$PATH" "$@" </dev/null
}

# Sourced the way run_logged runs it.
run_leaf() {
  on_machine "$@" bash -eE -c 'source "$1"' bash "$leaf"
}

expect_headers() {
  local description="$1" expected="$2"
  shift 2

  run_leaf "$@" >"$test_tmp/out" 2>"$test_tmp/err" || fail "$description" "$(<"$test_tmp/err")"
  [[ $(grep '^omarchy-pkg-add ' "$calls") == "omarchy-pkg-add ${expected:+$expected }v4l2loopback-dkms v4l2loopback-utils v4l2-relayd" ]] ||
    fail "$description" "expected headers: $expected
$(<"$calls")"
  grep -qx 'sudo tee /etc/modprobe.d/v4l2loopback-exclusive-caps.conf' "$calls" ||
    fail "$description" "the relay is not configured: $(<"$calls")"
  [[ -z $expected || ! -s $test_tmp/err ]] || fail "$description" "unexpected errors: $(<"$test_tmp/err")"
  pass "$description"
}

fake_modules arch 6.16.8-arch1-1 linux
fake_modules lts 6.12.48-1-lts linux-lts
fake_modules zen 6.16.8-zen1-1-zen linux-zen
fake_modules omarchy 6.16.8-arch1-1 linux 6.16.9-1-omarchy linux-omarchy
fake_modules cachyos 6.16.8-arch1-1 linux 6.16.9-2-cachyos linux-cachyos
fake_modules aurora 7.1.12-2-7-ARCH linux-aurora
fake_modules asahi 6.17.4-asahi-1-1-ARCH linux-asahi
fake_modules unpackaged
mkdir -p "$test_tmp/unpackaged/6.16.8-custom"

# x86 installs headers for the kernels the list names, as before: all of them
# when several are installed, including in an install chroot, which runs the
# ISO's kernel beside the target's linux and linux-omarchy.
expect_headers "stock Arch installs linux-headers" linux-headers x86 arch 6.16.8-arch1-1 "linux linux-firmware linux-api-headers"
expect_headers "linux-lts installs linux-lts-headers" linux-lts-headers x86 lts 6.12.48-1-lts "linux-lts linux-firmware"
expect_headers "linux-zen installs linux-zen-headers" linux-zen-headers x86 zen 6.16.8-zen1-1-zen "linux-zen linux-firmware"
expect_headers "every installed x86 kernel gets its headers" "linux-headers linux-omarchy-headers" x86 omarchy 6.16.9-1-omarchy "linux linux-firmware linux-omarchy"
expect_headers "an install chroot installs headers for every target kernel" "linux-headers linux-omarchy-headers" x86 omarchy 6.17.0-arch1-1 "linux linux-firmware linux-omarchy"
expect_headers "an x86 kernel the list does not name gets no headers, as before" linux-headers x86 cachyos 6.16.9-2-cachyos "linux linux-cachyos linux-firmware"

# Apple kernels are not on the x86 list, and a package pacman's search matches
# as linux (linux-aarch64 provides it) is not the kernel an Apple Mac boots.
expect_headers "an Aurora kernel installs linux-aurora-headers" linux-aurora-headers apple aurora 7.1.12-2-7-ARCH "linux-aurora linux-firmware"
expect_headers "an Asahi kernel installs linux-asahi-headers" linux-asahi-headers apple asahi 6.17.4-asahi-1-1-ARCH "linux-asahi linux-firmware"
expect_headers "Apple Silicon ignores what the x86 list matches" linux-aurora-headers apple aurora 7.1.12-2-7-ARCH "linux linux-aurora linux-firmware"

# A kernel no package owns has no headers to name; the relay still installs,
# as it did before, and the log says why DKMS has nothing to build against.
expect_headers "an Apple kernel no package owns still installs the relay" "" apple unpackaged 6.16.8-custom "linux-firmware"
grep -q 'pkgbase' "$test_tmp/err" || fail "a kernel no package owns is reported" "$(<"$test_tmp/err")"
pass "a kernel no package owns is reported"

# Existing installs get the fix from a migration that sources the leaf under
# the migration runner's strict mode.
on_machine apple aurora 7.1.12-2-7-ARCH "linux-aurora" bash -euo pipefail "$migration" >"$test_tmp/out" 2>"$test_tmp/err" ||
  fail "the migration installs linux-aurora-headers on Aurora" "$(<"$test_tmp/err")"
grep -qx 'omarchy-pkg-add linux-aurora-headers v4l2loopback-dkms v4l2loopback-utils v4l2-relayd' "$calls" ||
  fail "the migration installs linux-aurora-headers on Aurora" "$(<"$calls")"
pass "the migration installs linux-aurora-headers on Aurora"

CAMLINK=0 run_leaf x86 arch 6.16.8-arch1-1 linux >/dev/null 2>&1 || fail "no Cam Link installs nothing"
[[ ! -s $calls ]] || fail "no Cam Link installs nothing" "$(<"$calls")"
pass "no Cam Link installs nothing"
