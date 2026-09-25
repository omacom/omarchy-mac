#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration=$(grep -l 'Draw the pointer in software on every Apple Silicon Mac' "$ROOT"/migrations/*.sh)
(( $(wc -l <<<"$migration") == 1 )) || fail "one migration draws the Apple pointer in software" "$migration"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
cat >"$test_tmp/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
[[ $APPLE == "1" ]]
SH
cat >"$test_tmp/omarchy-setup-mac" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$CALLS"
SH
chmod +x "$test_tmp"/omarchy-*

run_migration() {
  APPLE=$1 CALLS="$test_tmp/calls" PATH="$test_tmp:$PATH" OMARCHY_PATH="$ROOT" \
    bash -euo pipefail "$migration" >/dev/null
}

run_migration 0
[[ ! -e $test_tmp/calls ]] || fail "other platforms skip the Apple cursor migration"
run_migration 1
[[ $(<"$test_tmp/calls") == "--user" ]] || fail "Apple Silicon runs only the per-user Mac setup" "$(<"$test_tmp/calls")"
pass "the Apple cursor migration runs the per-user Mac setup on Apple Silicon only"
