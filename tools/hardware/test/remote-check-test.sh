#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# A copy of remote-check beside a stand-in check, and an ssh that runs each
# command locally in a scratch "remote" /tmp.
tools="$test_tmp/tools"
stub_bin="$test_tmp/bin"
remote_tmp="$test_tmp/remote-tmp"
mkdir -p "$tools" "$stub_bin" "$remote_tmp"
printf 'export OMARCHY_PATH=/usr/share/omarchy\n' >"$remote_tmp/.bash_profile"
cp "$TOOLS/remote-check" "$tools/remote-check"
cat >"$tools/mac-check" <<'SH'
echo "check sees OMARCHY_PATH=${OMARCHY_PATH:-unset}"
exit 3
SH
cat >"$stub_bin/ssh" <<'SH'
#!/bin/bash
[[ $1 == "test-mac" ]] || exit 255
printf '%s\n' "$2" >>"$TEST_LOG"
command=${2//\/tmp\//$REMOTE_TMP/}
HOME=$REMOTE_TMP exec bash -c "$command"
SH
chmod +x "$stub_bin/ssh"

status=0
TEST_LOG="$test_tmp/ssh.log" REMOTE_TMP="$remote_tmp" PATH="$stub_bin:$PATH" \
  bash "$tools/remote-check" test-mac >"$test_tmp/out" 2>"$test_tmp/err" || status=$?

(( status == 3 )) || fail "remote-check exits with the check's status" "status $status: $(cat "$test_tmp/out" "$test_tmp/err")"
pass "remote-check exits with the check's status"

head -n1 "$test_tmp/out" | grep -Eq '^Hardware check of test-mac from omarchy-mac [^ ]+, [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}$' ||
  fail "the report is headed by host, revision and time" "$(cat "$test_tmp/out")"
grep -Fxq "check sees OMARCHY_PATH=/usr/share/omarchy" "$test_tmp/out" || fail "the check gets the login environment" "$(cat "$test_tmp/out")"
pass "the check runs from a file through a login shell under a header"

[[ -z $(ls -A "$remote_tmp" | grep -v '^\.' || true) ]] || fail "the copied check is removed from the Mac" "$(ls -A "$remote_tmp")"
copied=$(sed -n '1p' "$test_tmp/ssh.log")
[[ $copied == "mktemp /tmp/omarchy-mac-check.XXXXXX" ]] || fail "the check is copied to a fresh temporary file" "$copied"
grep -Eq "rm -f [^ ]+/omarchy-mac-check\.[A-Za-z0-9]+; exit" "$test_tmp/ssh.log" || fail "the removal targets the copied file" "$(cat "$test_tmp/ssh.log")"
pass "the copied check is removed from the Mac"

if bash "$TOOLS/remote-check" >/dev/null 2>&1; then
  fail "remote-check needs a host"
fi
if bash "$TOOLS/remote-check" --help >/dev/null 2>&1; then
  fail "remote-check refuses an option as a host"
fi
pass "remote-check needs exactly one host"
