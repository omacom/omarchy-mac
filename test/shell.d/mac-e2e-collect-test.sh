#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TOOL=$ROOT/bin/omarchy-mac-e2e-collect

[[ -f $TOOL ]] || fail "e2e collector is in bin/"
head -1 "$TOOL" | grep -qx '#!/bin/bash' || fail "e2e collector uses #!/bin/bash"
grep -q '^# omarchy:summary=' "$TOOL" || fail "e2e collector has omarchy:summary"
grep -q '^# omarchy:hidden=true' "$TOOL" || fail "e2e collector is hidden from the menu"
bash -n "$TOOL" || fail "e2e collector parses (bash -n)"
pass "e2e collector is a hidden omarchy-mac bin script"

OMARCHY_E2E_LIB=1
# shellcheck source=/dev/null
source "$TOOL"
pass "e2e collector can be sourced as a library"

# --- redaction ---

redact_equals() {
  local input=$1 expected=$2 label=$3 actual
  actual=$(printf '%s\n' "$input" | E2E_REDACT_HOST=testhost E2E_REDACT_USER=skytester E2E_REDACT_HOME=/home/skytester redact_stream)
  [[ $actual == "$expected" ]] || fail "$label" "got: $actual"
  pass "$label"
}

redact_equals 'Serial Number (system): C02XY9876543' 'Serial Number (system): [redacted]' 'redacts macOS serial lines'
redact_equals 'inet 192.168.1.50/24' 'inet [redacted-ip4]/24' 'redacts IPv4 addresses'
redact_equals 'ether aa:bb:cc:dd:ee:ff' 'ether [redacted-mac]' 'redacts MAC addresses'
redact_equals 'token=ghp_abcdefghijklmnop' 'token=[redacted]' 'redacts github-shaped tokens'
redact_equals 'skytester logged in' '[user] logged in' 'redacts live username'
redact_equals 'testhost kernel' '[host] kernel' 'redacts live hostname'
redact_equals '/home/skytester/.config/omarchy' '[home]/.config/omarchy' 'redacts home path'

kept=$(printf '%s\n' 'omarchy 4.0.3-1' | E2E_REDACT_HOST=testhost E2E_REDACT_USER=skytester E2E_REDACT_HOME=/home/skytester redact_stream)
[[ $kept == 'omarchy 4.0.3-1' ]] || fail "does not redact package versions" "got: $kept"
pass "does not redact package versions"

generic=$(printf '%s\n' 'alarm is the default user' | E2E_REDACT_HOST=alarm E2E_REDACT_USER=alarm E2E_REDACT_HOME=/root redact_stream)
printf '%s\n' "$generic" | grep -q 'alarm is the default user' || fail "does not redact generic alarm hostname/user"
pass "does not redact generic alarm hostname/user"

# --- capture format helpers ---

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

write_ev() {
  local path=$1 body=$2 rc=${3:-0}
  mkdir -p "$(dirname "$path")"
  {
    echo "+ fake"
    echo "-----"
    printf '%s\n' "$body"
    echo "-----"
    echo "exit=$rc"
  } >"$path"
}

# Baseline PASS requires uname success and Omarchy not already present.
mkdir -p "$tmp/good/00-baseline" "$tmp/good/graphical-1/06-smoke" "$tmp/good/final/07-persistence"
write_ev "$tmp/good/00-baseline/uname-a.txt" "Linux asahi 6.17.0-asahi"
write_ev "$tmp/good/00-baseline/freshness.txt" $'omarchy_share=1\nsetup_conf=1'
printf 'WANT_ENCRYPT=1\nSETUP_USER=pat\n' >"$tmp/good/saved-setup.conf"
write_ev "$tmp/good/final/findmnt-root.txt" "/ /dev/mapper/root btrfs rw"
write_ev "$tmp/good/final/findmnt-boot.txt" "/boot /dev/nvme0n1p5 vfat rw"
write_ev "$tmp/good/graphical-1/omarchy-version.txt" "4.0.3"
write_ev "$tmp/good/graphical-1/06-smoke/smoke-result.txt" $'hyprland=PASS\nRESULT=PASS'
write_ev "$tmp/good/final/07-persistence/setup-conf-exists.txt" "setup_conf=1"
write_ev "$tmp/good/final/07-persistence/setup-sudoers-exists.txt" "setup_sudoers=1"
write_ev "$tmp/good/final/07-persistence/setup-service-enabled.txt" "disabled"

verdicts=$(compute_verdicts "$tmp/good")
printf '%s\n' "$verdicts" | grep -qx 'baseline=PASS' || fail "good run: baseline PASS" "$verdicts"
printf '%s\n' "$verdicts" | grep -qx 'boot_layout=PASS' || fail "good run: boot_layout PASS" "$verdicts"
printf '%s\n' "$verdicts" | grep -qx 'encryption=PASS' || fail "good run: encryption PASS" "$verdicts"
printf '%s\n' "$verdicts" | grep -qx 'omarchy_stage=PASS' || fail "good run: omarchy_stage PASS" "$verdicts"
printf '%s\n' "$verdicts" | grep -qx 'first_login=PASS' || fail "good run: first_login PASS" "$verdicts"
printf '%s\n' "$verdicts" | grep -qx 'security=PASS' || fail "good run: security PASS" "$verdicts"
printf '%s\n' "$verdicts" | grep -qx 'cold_boot=SKIP' || fail "good run: cold_boot SKIP" "$verdicts"
printf '%s\n' "$verdicts" | grep -qx 'second_login=SKIP' || fail "good run: second_login SKIP" "$verdicts"
printf '%s\n' "$verdicts" | grep -qx 'overall=PASS' || fail "good run: overall PASS" "$verdicts"
pass "encrypted success path uses honest PASS/SKIP"

# Version alone must not PASS first login.
mkdir -p "$tmp/version-only"
write_ev "$tmp/version-only/omarchy-version.txt" "4.0.3"
write_ev "$tmp/version-only/00-baseline/uname-a.txt" "Linux"
write_ev "$tmp/version-only/00-baseline/freshness.txt" "omarchy_share=1"
verdicts=$(compute_verdicts "$tmp/version-only")
printf '%s\n' "$verdicts" | grep -qx 'first_login=SKIP' || fail "version-only does not PASS first_login" "$verdicts"
printf '%s\n' "$verdicts" | grep -qx 'overall=SKIP' || fail "version-only overall is SKIP not PASS" "$verdicts"
pass "omarchy version is not treated as first-login proof"

# Already-installed Asahi baseline is a FAIL, not a pass.
mkdir -p "$tmp/stale/00-baseline"
write_ev "$tmp/stale/00-baseline/uname-a.txt" "Linux"
write_ev "$tmp/stale/00-baseline/freshness.txt" "omarchy_share=0"
verdicts=$(compute_verdicts "$tmp/stale")
printf '%s\n' "$verdicts" | grep -qx 'baseline=FAIL' || fail "stale Asahi baseline is FAIL" "$verdicts"
pass "freshness marker rejects an already-installed baseline"

# Failure snapshot forces overall FAIL.
mkdir -p "$tmp/good/fail-1"
verdicts=$(compute_verdicts "$tmp/good")
printf '%s\n' "$verdicts" | grep -qx 'overall=FAIL' || fail "fail snapshot forces overall FAIL" "$verdicts"
pass "a fail snapshot forces overall FAIL"
