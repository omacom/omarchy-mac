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

# Laptop detection: Apple Silicon counts even without ACPI lid or DMI chassis.
OMARCHY_UNAME_M=x86_64 \
  OMARCHY_DMI_CHASSIS_TYPE_PATH="$tmp_dir/missing" \
  OMARCHY_APPLE_COMPATIBLE="$tmp_dir/compatible" \
  hw laptop && fail "x86_64 without lid or chassis is not a laptop" || true
pass "x86_64 without lid or chassis is not a laptop"

OMARCHY_UNAME_M=aarch64 \
  OMARCHY_DMI_CHASSIS_TYPE_PATH="$tmp_dir/missing" \
  OMARCHY_APPLE_COMPATIBLE="$tmp_dir/compatible" \
  hw laptop || fail "Apple Silicon is a laptop without ACPI lid or DMI"
pass "Apple Silicon is a laptop without ACPI lid or DMI"
