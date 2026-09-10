#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/setsid" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >"$TEST_LOG"
exec "$@"
SCRIPT
chmod +x "$tmp_dir/setsid"

cat >"$tmp_dir/omarchy-restart-gum" <<'SCRIPT'
#!/bin/bash
:
SCRIPT

cat >"$tmp_dir/uwsm-app" <<'SCRIPT'
#!/bin/bash
[[ ${1:-} == "--" ]] && shift
exec "$@"
SCRIPT

cat >"$tmp_dir/xdg-terminal-exec" <<'SCRIPT'
#!/bin/bash
while (($#)); do
  if [[ $1 == "-e" ]]; then
    shift
    exec "$@"
  fi
  shift
done
exit 1
SCRIPT

cat >"$tmp_dir/omarchy-show-logo" <<'SCRIPT'
#!/bin/bash
printf 'logo\n' >>"$TEST_LOG"
SCRIPT

cat >"$tmp_dir/omarchy-show-done" <<'SCRIPT'
#!/bin/bash
printf 'done\n' >>"$TEST_LOG"
SCRIPT

chmod +x "$tmp_dir"/*

export TEST_LOG="$tmp_dir/log"
export PATH="$tmp_dir:$ROOT/bin:$PATH"

: >"$TEST_LOG"

"$ROOT/bin/omarchy-launch-floating-terminal-with-presentation" "echo hello"

launch=$(<"$TEST_LOG")
[[ $launch == *"xdg-terminal-exec --app-id=org.omarchy.terminal"* ]] || fail "floating terminal launches Omarchy terminal" "$launch"
pass "floating terminal launches Omarchy terminal"

run_status_probe() {
  local child_command="$1" expected_status="$2"

  : >"$TEST_LOG"
  set +e
  "$ROOT/bin/omarchy-launch-floating-terminal-with-presentation" "$child_command"
  actual_status=$?
  set -e
  [[ $actual_status == "$expected_status" ]] ||
    fail "presentation preserves child status from '$child_command'" "expected $expected_status, got $actual_status"
  pass "presentation preserves child status from '$child_command'"
}

run_status_probe true 0
grep -Fxq 'done' "$TEST_LOG" || fail "presentation shows Done after successful child"
pass "presentation shows Done after successful child"

run_status_probe false 1
! grep -Fxq 'done' "$TEST_LOG" || fail "presentation does not show Done after failed child"
pass "presentation does not show Done after failed child"

run_status_probe "bash -c 'exit 130'" 130
! grep -Fxq 'done' "$TEST_LOG" || fail "presentation does not translate status 130 into Done"
pass "presentation preserves status 130 without cancellation translation"
