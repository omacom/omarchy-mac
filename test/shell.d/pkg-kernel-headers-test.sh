#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# DKMS modules build against the headers of the kernel that runs, and every
# Arch kernel package records its pkgbase beside its modules. The helper names
# the headers after it, whatever the platform.

helper="$ROOT/bin/omarchy-pkg-kernel-headers"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/uname" <<'SH'
#!/bin/bash
if [[ ${1:-} == "-r" ]]; then
  printf '%s\n' "$KERNEL_RELEASE"
else
  exec /usr/bin/uname "$@"
fi
SH
chmod +x "$stub_bin/uname"

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

headers_for() {
  OMARCHY_MODULES_ROOT="$test_tmp/$1" KERNEL_RELEASE="$2" PATH="$stub_bin:$PATH" "$helper"
}

expect_headers() {
  local description="$1" tree="$2" release="$3" expected="$4" actual

  actual=$(headers_for "$tree" "$release" 2>"$test_tmp/err") || fail "$description" "$(<"$test_tmp/err")"
  [[ $actual == "$expected" ]] || fail "$description" "expected: $expected
actual:   $actual"
  pass "$description"
}

expect_refusal() {
  local description="$1" tree="$2" release="$3" actual status=0

  actual=$(headers_for "$tree" "$release" 2>"$test_tmp/err") || status=$?
  if (( status == 0 )) || [[ -n $actual || ! -s $test_tmp/err ]]; then
    fail "$description" "status: $status
stdout: $actual
stderr: $(<"$test_tmp/err")"
  fi
  pass "$description"
}

# Root picks what gets installed, so it reads the live modules tree and the
# system uname, never the fixture its environment names. Run it as root when
# the suite is root and as namespaced root otherwise.
fake_modules fixture 9.9.9-fixture linux-fixture
root_runner=()
if (( EUID != 0 )); then
  root_runner=(unshare --user --map-root-user)
fi
if (( EUID == 0 )) || unshare --user --map-root-user true 2>/dev/null; then
  live_status=0
  live=$("${root_runner[@]}" "$helper" 2>/dev/null) || live_status=$?
  overridden_status=0
  overridden=$(OMARCHY_MODULES_ROOT="$test_tmp/fixture" KERNEL_RELEASE=9.9.9-fixture PATH="$stub_bin:$PATH" \
    "${root_runner[@]}" "$helper" 2>/dev/null) || overridden_status=$?
  if [[ $overridden == "linux-fixture-headers" || $overridden != "$live" ]] || (( overridden_status != live_status )); then
    fail "root ignores a modules fixture in its environment" "live: $live ($live_status)
with fixture: $overridden ($overridden_status)"
  fi
  pass "root ignores a modules fixture in its environment"
else
  pass "no unprivileged user namespace; skipping the root override probe"
fi

if (( EUID == 0 )); then
  pass "running as root, where omarchy-pkg-kernel-headers ignores fixtures; skipping the kernel fixtures"
  exit 0
fi

fake_modules aurora 7.1.12-2-7-ARCH linux-aurora
fake_modules asahi 6.17.4-asahi-1-1-ARCH linux-asahi
fake_modules arch 6.16.8-arch1-1 linux
fake_modules two-kernels 6.16.8-arch1-1 linux 6.12.48-1-lts linux-lts
fake_modules one-kernel-twice 6.16.8-arch1-1 linux 6.16.9-arch1-1 linux
fake_modules upgraded 7.1.13-1-1-ARCH linux-aurora
mkdir -p "$test_tmp/upgraded/7.1.12-2-7-ARCH/updates/dkms"
fake_modules no-kernels
fake_modules bad-pkgbase 7.1.12-2-7-ARCH "../../etc"

# The platforms the Xbox controller install meets, as their kernels lay out
# /usr/lib/modules; the Aurora release is the one an M2 Max runs.
expect_headers "an Aurora kernel needs linux-aurora-headers" aurora 7.1.12-2-7-ARCH linux-aurora-headers
expect_headers "an Asahi kernel needs linux-asahi-headers" asahi 6.17.4-asahi-1-1-ARCH linux-asahi-headers
expect_headers "a stock Arch kernel needs linux-headers" arch 6.16.8-arch1-1 linux-headers
expect_headers "the running kernel wins over other installed kernels" two-kernels 6.12.48-1-lts linux-lts-headers

# Until the next boot, an upgrade leaves the running kernel with no pkgbase,
# at most a directory of DKMS leftovers; an install chroot runs a kernel the
# target does not have. The installed kernel answers when there is only one.
expect_headers "an upgraded kernel answers until the next boot" upgraded 7.1.12-2-7-ARCH linux-aurora-headers
expect_headers "an install chroot answers for the target's kernel" arch 6.17.0-arch1-1 linux-headers
expect_headers "installed releases of one kernel agree" one-kernel-twice 6.17.0-arch1-1 linux-headers
expect_refusal "several installed kernels and none running is ambiguous" two-kernels 6.17.0-arch1-1
expect_refusal "no installed kernel leaves no headers to name" no-kernels 6.16.8-arch1-1
expect_refusal "a pkgbase that is not a package name is ignored" bad-pkgbase 7.1.12-2-7-ARCH
expect_refusal "an unreadable kernel release is refused" arch ""
