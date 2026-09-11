#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fake_bin="$test_tmp/bin"
fake_omarchy="$test_tmp/omarchy"
calls="$test_tmp/calls"
mkdir -p "$fake_bin" "$fake_omarchy/bin"

cat >"$fake_bin/plymouth-set-default-theme" <<'STUB'
#!/bin/bash
exit 0
STUB

cp "$ROOT/bin/omarchy-refresh-plymouth" "$fake_omarchy/bin/omarchy-refresh-plymouth"
cat >"$fake_omarchy/bin/omarchy-plymouth-set" <<'STUB'
#!/bin/bash
set -euo pipefail

printf '%s\n' "${OMARCHY_INSTALL_USER:-deferred}" "$*" >>"$OMARCHY_TEST_CALLS"
exit "${OMARCHY_TEST_PUBLISH_STATUS:-0}"
STUB

chmod +x "$fake_bin"/* "$fake_omarchy/bin"/*

run_install_leaf() {
  PATH="$fake_bin:$fake_omarchy/bin:/usr/bin:/bin" \
    OMARCHY_PATH="$fake_omarchy" \
    OMARCHY_TEST_CALLS="$calls" \
    bash -e -c 'source "$1"' bash "$ROOT/install/login/plymouth.sh"
}

OMARCHY_INSTALL_USER=owner run_install_leaf
[[ $(cat "$calls") == $'owner\n--refresh-default' ]] ||
  fail "fresh-install Plymouth setup reaches the fixed-default publisher" "$(cat "$calls")"
pass "fresh-install Plymouth setup refreshes the packaged default"

rm -f "$calls"
OMARCHY_INSTALL_USER= run_install_leaf
[[ $(cat "$calls") == $'deferred\n--refresh-default' ]] ||
  fail "deferred setup reaches the fixed-default publisher without an owner" "$(cat "$calls")"
pass "deferred provisioning refreshes Plymouth before an install user exists"

rm -f "$calls"
status=0
OMARCHY_INSTALL_USER=owner OMARCHY_TEST_PUBLISH_STATUS=42 run_install_leaf || status=$?
(( status == 42 )) ||
  fail "Plymouth publication failure propagates out of system setup" "exit status: $status"
pass "fresh-install Plymouth setup propagates publication failures"
