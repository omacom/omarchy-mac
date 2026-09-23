#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
python3 "$ROOT/test/vm/mac-image/test_admit.py"
python3 "$ROOT/test/vm/mac-image/test_loop_guard.py"
python3 "$ROOT/test/vm/mac-image/test_audit_export.py"
python3 "$ROOT/test/vm/mac-image/test_launch_private.py"
python3 "$ROOT/test/vm/mac-image/test_disposable_payload.py"
python3 "$ROOT/test/vm/mac-image/test_verify_generic_kernel.py"
python3 "$ROOT/test/vm/mac-image/test_loop_nodes.py"
python3 "$ROOT/test/vm/mac-image/test_adapt_detector.py"
bash -n "$ROOT/test/vm/mac-image/run"
pass "private VM input admission rejects substitution, unsafe images and dirty verifier code"
