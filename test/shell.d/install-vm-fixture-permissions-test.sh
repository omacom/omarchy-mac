#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture="$work/fixture"
mkdir -m 700 "$fixture"
mkdir -m 700 "$fixture/channel-stable"
printf 'verified database bytes\n' > "$fixture/channel-stable/omarchy.db"
printf 'stable\n' > "$fixture/channel"
chmod 600 "$fixture/channel-stable/omarchy.db" "$fixture/channel"
before=$(sha256sum "$fixture/channel-stable/omarchy.db")
eval "$(sed -n '/^expose_verified_fixture() {/,/^}/p' "$ROOT/test/vm/prepare-channel-fixture")"
expose_verified_fixture
[[ $(stat -c %a "$fixture") == "755" && $(stat -c %a "$fixture/channel-stable") == "755" ]] || fail "downloader needs directory traversal"
[[ $(stat -c %a "$fixture/channel-stable/omarchy.db") == "644" && $(stat -c %a "$fixture/channel") == "644" ]] || fail "downloader needs read-only public fixture files"
[[ $(sha256sum "$fixture/channel-stable/omarchy.db") == "$before" ]] || fail "permission normalization must preserve verified bytes"
# This permission leaf must run only after real snapshot preparation succeeds.
python3 - "$ROOT/test/vm/prepare-channel-fixture" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert text.index('"$publisher/scripts/channel-snapshot.py" prepare') < text.rindex('\nexpose_verified_fixture\n')
assert 'set -euo pipefail' in text
PY
pass "verified fixture is readable without granting downloader write access"
