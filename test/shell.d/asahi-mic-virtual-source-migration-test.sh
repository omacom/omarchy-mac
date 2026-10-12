#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-hw-apple" <<'STUB'
#!/bin/bash
[[ ${APPLE:-true} == "true" ]]
STUB

cat >"$stub_bin/systemctl" <<'STUB'
#!/bin/bash

printf '%s\n' "$*" >>"$SYSTEMCTL_CALLS"

case "$*" in
  '--user show-environment')
    [[ ${MANAGER_AVAILABLE:-true} == "true" ]]
    ;;
  '--user is-active --quiet omarchy-asahi-mic.service')
    [[ ${MAPPER_ACTIVE:-true} == "true" ]]
    ;;
  '--user restart omarchy-asahi-mic.service')
    if [[ ${FAIL_RESTART:-false} == "true" ]]; then
      echo "restart failed" >&2
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub_bin/omarchy-hw-apple" "$stub_bin/systemctl"

migration="$ROOT/migrations/1791828817.sh"

run_migration() {
  local calls="$1"
  shift
  SYSTEMCTL_CALLS="$calls" PATH="$stub_bin:$PATH" "$@" bash -euo pipefail "$migration"
}

calls="$test_tmp/running"
if run_migration "$calls" env >/dev/null && grep -qx -- '--user restart omarchy-asahi-mic.service' "$calls"; then
  pass "a running old watcher is restarted onto the virtual-source mapper"
else
  fail "a running old watcher is restarted onto the virtual-source mapper" "$(cat "$calls" 2>/dev/null)"
fi

calls="$test_tmp/inactive"
if run_migration "$calls" env MAPPER_ACTIVE=false >/dev/null && ! grep -q 'restart' "$calls"; then
  pass "an inactive or disabled mapper is left alone"
else
  fail "an inactive or disabled mapper is left alone" "$(cat "$calls" 2>/dev/null)"
fi

calls="$test_tmp/no-manager"
if run_migration "$calls" env MANAGER_AVAILABLE=false >/dev/null && ! grep -q 'restart' "$calls"; then
  pass "no live user manager means nothing to restart"
else
  fail "no live user manager means nothing to restart" "$(cat "$calls" 2>/dev/null)"
fi

calls="$test_tmp/not-apple"
if run_migration "$calls" env APPLE=false >/dev/null && [[ ! -e $calls ]]; then
  pass "non-Apple machines skip the migration without touching systemd"
else
  fail "non-Apple machines skip the migration without touching systemd" "$(cat "$calls" 2>/dev/null)"
fi

calls="$test_tmp/failed"
if ! output=$(run_migration "$calls" env FAIL_RESTART=true 2>&1) && [[ $output == *"retried by omarchy-migrate"* ]]; then
  pass "a failed restart keeps the migration pending"
else
  fail "a failed restart keeps the migration pending" "$output"
fi

if [[ $(stat -c '%a' "$migration") == "644" ]] && [[ $(head -c 2 "$migration") != "#!" ]] && head -1 "$migration" | grep -q '^echo '; then
  pass "migration follows the file conventions"
else
  fail "migration follows the file conventions"
fi
