#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

for harness in "$ROOT/test/vm/run-install" "$ROOT/test/vm/run-selective-edge"; do
  grep -q 'omarchy commands >/dev/null' "$harness" || fail "vm harness lists commands for smoke validation: $harness"
  ! grep -q 'omarchy commands --check >/dev/null' "$harness" || fail "vm harness avoids strict metadata validation for external command packages: $harness"
done

pass "vm install harnesses perform command smoke checks without metadata-only gating"
