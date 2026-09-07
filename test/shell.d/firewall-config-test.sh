#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

cat >"$stub_dir/ufw" <<'STUB'
#!/bin/bash
printf 'ufw %s\n' "$*" >>"$TEST_LOG"
# UFW reloads the live firewall for policy/rule edits when ENABLED=yes.
if ! grep -qx 'ENABLED=no' "$TEST_UFW_CONFIG"; then
  echo 'attempted live firewall reload' >&2
  exit 90
fi
case ${1:-} in
  default|allow) ;;
  *) echo 'unexpected live firewall command' >&2; exit 91 ;;
esac
[[ ${TEST_FAIL_AT:-} != "ufw" ]] || exit 42
STUB

cat >"$stub_dir/ufw-docker" <<'STUB'
#!/bin/bash
set -euo pipefail
PATH="/bin:/usr/bin:/sbin:/usr/sbin:/snap/bin/"
printf 'ufw-docker %s\n' "$*" >>"$TEST_LOG"
if ! ufw status 2>/dev/null | grep -Fq 'Status: active'; then
  echo 'inactive' >&2
  exit 1
fi
[[ ${TEST_FAIL_AT:-} != "docker" ]] || exit 43
STUB

cat >"$stub_dir/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
[[ $* == "enable ufw" ]] || exit 92
[[ ${TEST_FAIL_AT:-} != "systemctl" ]] || exit 44
STUB
chmod +x "$stub_dir/ufw" "$stub_dir/ufw-docker" "$stub_dir/systemctl"

export TEST_LOG="$stub_dir/firewall.log"
export TEST_UFW_CONFIG="$stub_dir/ufw.conf"
# Redirect the leaf's one absolute configuration path into the fixture. All
# file operations stay real, including backup, temporary disable, and restore.
sed "s#/etc/ufw/ufw.conf#$TEST_UFW_CONFIG#g" "$ROOT/install/config/firewall.sh" >"$stub_dir/firewall.sh"

run_config() {
  : >"$TEST_LOG"
  PATH="$stub_dir:$PATH" bash -eE -c '
    trap '\''echo caller-exit >>"$TEST_LOG"'\'' EXIT
    source "$1"
  ' bash "$stub_dir/firewall.sh"
}

printf '# preserved comment\nENABLED=no\nLOGLEVEL=low\n' >"$TEST_UFW_CONFIG"
for run in first repeat; do
  run_config || fail "$run firewall configuration must stay offline"
  grep -q '^ufw-docker install$' "$TEST_LOG" || fail "ufw-docker rules are installed"
  grep -q '^systemctl enable ufw$' "$TEST_LOG" || fail "ufw is enabled for next boot"
  grep -qx 'ENABLED=yes' "$TEST_UFW_CONFIG" || fail "successful setup enables next boot"
  [[ $(grep -c '^caller-exit$' "$TEST_LOG") == "1" ]] || fail "source must preserve caller EXIT trap"
  pass "$run firewall setup edits rules without reloading the live firewall"
done

for enabled in no yes; do
  for failure in ufw docker systemctl; do
    printf '# preserved comment\nENABLED=%s\nLOGLEVEL=low\n' "$enabled" >"$TEST_UFW_CONFIG"
    cp "$TEST_UFW_CONFIG" "$stub_dir/expected.conf"
    status=0
    TEST_FAIL_AT="$failure" run_config || status=$?
    case $failure in
      ufw) expected_status=42 ;;
      docker) expected_status=43 ;;
      systemctl) expected_status=44 ;;
    esac
    (( status == expected_status )) || fail "$failure failure must propagate"
    cmp "$stub_dir/expected.conf" "$TEST_UFW_CONFIG" || fail "$failure failure must restore prior UFW state ($enabled)"
    [[ $(grep -c '^caller-exit$' "$TEST_LOG") == "1" ]] || fail "failure must preserve caller EXIT trap"
  done
  pass "failed firewall setup restores prior ENABLED=$enabled and caller cleanup"
done
