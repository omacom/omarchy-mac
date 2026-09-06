#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/lspci" <<'SH'
#!/bin/bash
printf 'lspci\n' >>"$OMARCHY_TEST_GPU_SCAN_LOG"
printf '%s\n' "${OMARCHY_TEST_GPU:-}"
SH

cat >"$stub_bin/omarchy-hw-nvidia-gsp" <<'SH'
#!/bin/bash
printf 'nvidia-gsp\n' >>"$OMARCHY_TEST_GPU_SCAN_LOG"
exit 1
SH

cat >"$stub_bin/omarchy-hw-nvidia-without-gsp" <<'SH'
#!/bin/bash
printf 'nvidia-without-gsp\n' >>"$OMARCHY_TEST_GPU_SCAN_LOG"
exit 1
SH

cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$OMARCHY_TEST_PKG_ADD_CALLED"
exit "${OMARCHY_TEST_PKG_STATUS:-0}"
SH

chmod +x "$stub_bin"/*

export OMARCHY_TEST_PKG_ADD_CALLED="$test_tmp/pkg-add-called"
export OMARCHY_TEST_GPU_SCAN_LOG="$test_tmp/gpu-scanned"

if ! OMARCHY_UNAME_M=x86_64 PATH="$stub_bin:$ROOT/bin:$PATH" bash "$ROOT/bin/omarchy-install-gaming-gpu-lib32" >"$test_tmp/output" 2>&1; then
  fail "the GPU helper succeeds when no supported GPU is detected"
fi

[[ ! -e $OMARCHY_TEST_PKG_ADD_CALLED ]] ||
  fail "the GPU helper does not try to install an empty package list"
grep -Fq 'No supported GPU detected' "$test_tmp/output" ||
  fail "the GPU helper explains why it skipped lib32 drivers"
pass "the GPU helper treats an unsupported GPU as a successful no-op"

OMARCHY_UNAME_M=x86_64 OMARCHY_TEST_GPU='VGA compatible controller: Intel Graphics' \
  PATH="$stub_bin:$ROOT/bin:$PATH" bash "$ROOT/bin/omarchy-install-gaming-gpu-lib32" >"$test_tmp/output" 2>&1 ||
  fail "x86 installs lib32 drivers for its detected GPU"
[[ $(cat "$OMARCHY_TEST_PKG_ADD_CALLED") == lib32-vulkan-intel ]] || fail "x86 selects the Intel lib32 package"
pass "the explicit x86 scenario retains its GPU package selection"

for arch in aarch64 arm64 unknown; do
  rm -f "$OMARCHY_TEST_PKG_ADD_CALLED" "$OMARCHY_TEST_GPU_SCAN_LOG"
  status=0
  OMARCHY_UNAME_M="$arch" OMARCHY_TEST_GPU='VGA compatible controller: Intel Graphics' \
    PATH="$stub_bin:$ROOT/bin:$PATH" bash "$ROOT/bin/omarchy-install-gaming-gpu-lib32" >"$test_tmp/output" 2>&1 || status=$?
  if [[ $arch == unknown ]]; then
    (( status != 0 )) || fail "unknown architecture stops before GPU or package operations"
  else
    (( status == 0 )) || fail "$arch skips x86 lib32 drivers successfully"
    grep -Fq 'Skipping x86 lib32 graphics packages on aarch64.' "$test_tmp/output" || fail "ARM explains the architecture-specific skip"
  fi
  [[ ! -e $OMARCHY_TEST_PKG_ADD_CALLED && ! -e $OMARCHY_TEST_GPU_SCAN_LOG ]] ||
    fail "$arch must not scan GPUs or install x86 packages"
done
pass "ARM aliases skip lib32 drivers and unknown architecture fails before hardware or package operations"
