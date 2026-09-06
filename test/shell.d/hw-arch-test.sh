#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

hw() {
  local name="$1"
  shift
  PATH="$ROOT/bin:$PATH" "$ROOT/bin/omarchy-hw-$name" "$@"
}

# x86_64: architecture printer and both booleans.
arch=$(OMARCHY_UNAME_M=x86_64 hw arch)
[[ $arch == "x86_64" ]] || fail "x86_64 prints x86_64" "actual: $arch"
pass "x86_64 prints x86_64"

OMARCHY_UNAME_M=x86_64 hw aarch64 && fail "x86_64 is not aarch64" || true
pass "x86_64 is not aarch64"

# A fake apple device-tree on x86 must not count as Apple Silicon.
printf 'apple,j413\n' >"$tmp_dir/compatible"
OMARCHY_UNAME_M=x86_64 OMARCHY_APPLE_COMPATIBLE="$tmp_dir/compatible" hw apple-silicon &&
  fail "x86_64 with an apple DT is not Apple Silicon" || true
pass "x86_64 with an apple DT is not Apple Silicon"

# aarch64 without apple DT: ARM path, not Apple hardware.
arch=$(OMARCHY_UNAME_M=aarch64 hw arch)
[[ $arch == "aarch64" ]] || fail "aarch64 prints aarch64" "actual: $arch"
pass "aarch64 prints aarch64"

OMARCHY_UNAME_M=aarch64 hw aarch64 || fail "aarch64 detects aarch64"
pass "aarch64 detects aarch64"

OMARCHY_UNAME_M=aarch64 OMARCHY_APPLE_COMPATIBLE="$tmp_dir/missing" hw apple-silicon &&
  fail "aarch64 without apple DT is not Apple Silicon" || true
pass "aarch64 without apple DT is not Apple Silicon"

# arm64 is an alias of aarch64.
arch=$(OMARCHY_UNAME_M=arm64 hw arch)
[[ $arch == "aarch64" ]] || fail "arm64 canonicalizes to aarch64" "actual: $arch"
pass "arm64 canonicalizes to aarch64"

OMARCHY_UNAME_M=arm64 hw aarch64 || fail "arm64 detects as aarch64"
pass "arm64 detects as aarch64"

for unsupported in riscv64 armv7l unknown; do
  if arch=$(OMARCHY_UNAME_M="$unsupported" hw arch); then
    fail "unsupported architectures must fail detection" "$unsupported returned: $arch"
  fi
  [[ -z $arch ]] || fail "unsupported architectures print no canonical name" "$arch"
done
pass "unsupported architectures cannot be mistaken for x86_64"

# A failed uname must fail even if it wrote a recognized architecture first.
uname() { printf '%s\n' x86_64; return 1; }
export -f uname
if arch=$(OMARCHY_UNAME_M= hw arch); then
  fail "failed uname must fail architecture detection" "$arch"
fi
unset -f uname
[[ -z $arch ]] || fail "failed detection prints no canonical name" "$arch"
pass "failed uname cannot be mistaken for x86_64"

# aarch64 + apple DT: Apple Silicon.
OMARCHY_UNAME_M=aarch64 OMARCHY_APPLE_COMPATIBLE="$tmp_dir/compatible" hw apple-silicon ||
  fail "aarch64 with apple DT is Apple Silicon"
pass "aarch64 with apple DT is Apple Silicon"

# Both Boolean detectors share the canonical helper, including uname failure.
for emitted in aarch64 arm64 x86_64; do
  uname() { printf '%s\n' "$OMARCHY_TEST_UNAME_OUTPUT"; return 1; }
  export -f uname
  export OMARCHY_TEST_UNAME_OUTPUT="$emitted"
  for detector in arch aarch64 apple-silicon; do
    if OMARCHY_UNAME_M= OMARCHY_APPLE_COMPATIBLE="$tmp_dir/compatible" hw "$detector" >/dev/null; then
      fail "failed uname cannot satisfy $detector even when it prints $emitted"
    fi
  done
  unset -f uname
done
pass "all architecture and Apple detectors reject recognized output from a failed uname"

printf 'pineapple,board\0vendor,apple-similar\0' >"$tmp_dir/compatible"
if OMARCHY_UNAME_M=aarch64 OMARCHY_APPLE_COMPATIBLE="$tmp_dir/compatible" hw apple-silicon; then
  fail "an Apple substring is not the Apple device-tree vendor"
fi
printf 'vendor,board\0apple,arm-platform\0' >"$tmp_dir/compatible"
OMARCHY_UNAME_M=arm64 OMARCHY_APPLE_COMPATIBLE="$tmp_dir/compatible" hw apple-silicon ||
  fail "Apple compatible identity can follow another NUL-delimited entry"
pass "Apple detection matches vendor entries in the complete device-tree list"

chmod 000 "$tmp_dir/compatible"
if OMARCHY_UNAME_M=aarch64 OMARCHY_APPLE_COMPATIBLE="$tmp_dir/compatible" hw apple-silicon; then
  fail "unreadable firmware cannot establish Apple identity"
fi
chmod 600 "$tmp_dir/compatible"
pass "Apple detection rejects unreadable firmware"
