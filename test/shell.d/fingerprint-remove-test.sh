#!/bin/bash
#
# Removing fingerprint authentication drops the packages the setup installed. A
# platform that names its readers supplied their libfprint, so only fprintd
# goes there. Privileged calls and package removal are stubbed.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
export CALL_LOG="$scratch/calls"
export PATH="$scratch/bin:$ROOT/bin:$PATH"

cat > "$scratch/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$CALL_LOG"
STUB
cat > "$scratch/bin/omarchy-pkg-drop" <<'STUB'
#!/bin/bash
printf 'drop %s\n' "$*" >> "$CALL_LOG"
STUB
chmod +x "$scratch/bin/"*

platform_root="$scratch/platform"
mkdir -p "$platform_root"
platform_root_copy "$ROOT/bin/omarchy-remove-security-fingerprint" "$scratch/remove" "$platform_root"

run_remove() {
  : > "$CALL_LOG"
  "$scratch/remove" > "$scratch/output" 2>&1 || fail "removal succeeds" "$(cat "$scratch/output")"
}

run_remove
grep -qx 'drop fprintd libfprint libfprint-git' "$CALL_LOG" ||
  fail "removal drops fprintd and either libfprint" "$(cat "$CALL_LOG")"
pass "removal drops fprintd and the libfprint the setup installed"

printf '/sys/bus/platform/drivers/apple_sep/*/diag/touchid ready\n' >"$platform_root/fingerprint-readers"
run_remove
grep -qx 'drop fprintd' "$CALL_LOG" ||
  fail "removal leaves a platform-named reader's libfprint installed" "$(cat "$CALL_LOG")"
pass "removal leaves the libfprint of a platform that names its readers"
