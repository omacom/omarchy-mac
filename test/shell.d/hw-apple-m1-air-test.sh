#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

compatible="$tmp_dir/compatible"
model="$tmp_dir/model"
detector="$ROOT/bin/omarchy-hw-apple-m1-air"

detect() {
  OMARCHY_UNAME_M="${1:-aarch64}" \
    OMARCHY_APPLE_COMPATIBLE="$compatible" \
    OMARCHY_APPLE_MODEL="$model" \
    "$detector"
}

printf 'apple,j313\0apple,t8103\0apple,arm-platform\0' >"$compatible"
printf 'Apple MacBook Air (M1, 2020)\0' >"$model"

detect || fail "the M1 MacBook Air device tree is detected"
pass "the M1 MacBook Air device tree is detected"

detect arm64 || fail "arm64 is accepted as an aarch64 alias"
pass "arm64 is accepted as an aarch64 alias"

detect x86_64 && fail "matching device-tree fixtures do not make x86 Apple Silicon" || true
pass "matching device-tree fixtures do not make x86 Apple Silicon"

uname() { printf '%s\n' aarch64; return 1; }
export -f uname
OMARCHY_UNAME_M= \
  OMARCHY_APPLE_COMPATIBLE="$compatible" \
  OMARCHY_APPLE_MODEL="$model" \
  "$detector" && fail "a failed architecture probe cannot match the M1 Air" || true
unset -f uname
pass "a failed architecture probe cannot match the M1 Air"

printf 'apple,j3130\0apple,t8103\0' >"$compatible"
detect && fail "a compatible prefix does not match the M1 Air" || true
pass "a compatible prefix does not match the M1 Air"

printf 'apple,j313\0apple,t8103\0' >"$compatible"
printf 'Apple MacBook Pro (13-inch, M1, 2020)\0' >"$model"
detect && fail "another M1 Mac model is not detected as the M1 Air" || true
pass "another M1 Mac model is not detected as the M1 Air"

OMARCHY_UNAME_M=aarch64 \
  OMARCHY_APPLE_COMPATIBLE="$tmp_dir/missing-compatible" \
  OMARCHY_APPLE_MODEL="$tmp_dir/missing-model" \
  "$detector" && fail "missing device-tree properties do not match" || true
pass "missing device-tree properties do not match"
