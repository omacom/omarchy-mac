#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls"
mkdir -p "$stub_bin"

cat >"$stub_bin/rfkill" <<'SH'
#!/bin/bash
printf 'rfkill %s\n' "$*" >>"$CALLS"
if [[ ${1:-} == "list" ]]; then
  cat <<'EOF'
1: phy0: Wireless LAN
	Soft blocked: no
	Hard blocked: no
EOF
fi
exit 0
SH

cat >"$stub_bin/nmcli" <<'SH'
#!/bin/bash
printf 'nmcli %s\n' "$*" >>"$CALLS"
if [[ ${NMCLI_FAIL:-} == "$*" ]]; then
  echo "Error: failed to set Wi-Fi radio: Not authorized to perform this operation" >&2
  exit 1
fi
exit 0
SH

chmod +x "$stub_bin"/*

run_wifi() {
  : >"$calls"
  CALLS="$calls" PATH="$stub_bin:$PATH" "$ROOT/bin/omarchy-restart-wifi" "$@"
}

run_wifi >/dev/null
grep -Fx 'nmcli radio wifi on' "$calls" >/dev/null || fail "restart wifi turns the radio on"
grep -Fx 'rfkill list wifi' "$calls" >/dev/null || fail "restart wifi lists the adapter after a successful restart"
pass "restart wifi unblocks, enables, and lists wifi on success"

if NMCLI_FAIL='radio wifi on' run_wifi >/dev/null 2>"$test_tmp/err"; then
  fail "restart wifi fails when nmcli rejects the radio change"
fi
grep -F 'Not authorized' "$test_tmp/err" >/dev/null ||
  fail "restart wifi keeps the nmcli error" "$(cat "$test_tmp/err")"
if grep -Fx 'rfkill list wifi' "$calls" >/dev/null; then
  fail "restart wifi does not treat a later rfkill list as success"
fi
pass "restart wifi returns nonzero when NetworkManager rejects the operation"
