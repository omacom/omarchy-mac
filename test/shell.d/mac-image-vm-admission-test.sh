#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
python3 "$ROOT/test/vm/mac-image/test_admit.py"
python3 "$ROOT/test/vm/mac-image/test_loop_guard.py"
python3 "$ROOT/test/vm/mac-image/test_audit_export.py"
python3 "$ROOT/test/vm/mac-image/test_launch_private.py"
bash -n "$ROOT/test/vm/mac-image/run"
pass "private VM input admission rejects substitution, unsafe images and dirty verifier code"
