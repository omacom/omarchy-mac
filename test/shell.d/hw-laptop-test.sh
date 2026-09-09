#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
acpi_lid="$test_tmp/acpi/button/lid"
dmi_chassis="$test_tmp/chassis_type"
mkdir -p "$stub_bin" "$acpi_lid/macbook"

cat >"$stub_bin/busctl" <<'SH'
#!/bin/bash
printf '%s\n' "${OMARCHY_TEST_LID_STATE:-b false}"
SH
chmod +x "$stub_bin/busctl"

run_laptop() {
  OMARCHY_DMI_CHASSIS_TYPE_PATH="$dmi_chassis" \
    OMARCHY_ACPI_LID_PATH="$acpi_lid" \
    OMARCHY_UNAME_M="${OMARCHY_UNAME_M:-x86_64}" \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    "$ROOT/bin/omarchy-hw-laptop"
}

run_lid_closed() {
  local lid_state="$1"

  OMARCHY_ACPI_LID_PATH="$acpi_lid" \
    PATH="$stub_bin:$PATH" \
    OMARCHY_TEST_LID_STATE="$lid_state" \
    "$ROOT/bin/omarchy-hw-laptop-closed"
}

printf '9\n' >"$dmi_chassis"
run_laptop || fail "DMI laptop chassis is recognized when ACPI is absent"
pass "DMI laptop chassis is recognized when ACPI is absent"

printf '3\n' >"$dmi_chassis"
if run_laptop; then
  fail "a desktop DMI chassis is not classified as a laptop"
fi
pass "a desktop DMI chassis is not classified as a laptop"

rm -f "$dmi_chassis"
printf 'apple,j413\n' >"$test_tmp/compatible"
OMARCHY_UNAME_M=aarch64 OMARCHY_APPLE_COMPATIBLE="$test_tmp/compatible" \
  OMARCHY_DMI_CHASSIS_TYPE_PATH="$dmi_chassis" \
  PATH="$stub_bin:$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-hw-laptop" ||
  fail "Apple Silicon with no DMI chassis is a laptop"
pass "Apple Silicon with no DMI chassis is a laptop"

printf 'closed\n' >"$acpi_lid/macbook/state"
run_lid_closed not-a-property ||
  fail "the ACPI fallback recognizes a closed lid"
pass "the ACPI fallback recognizes a closed lid"

printf 'open\n' >"$acpi_lid/macbook/state"
if run_lid_closed not-a-property; then
  fail "the ACPI fallback recognizes an open lid"
fi
pass "the ACPI fallback recognizes an open lid"

run_lid_closed 'b true' ||
  fail "logind recognizes an Apple Silicon closed lid"
pass "logind recognizes an Apple Silicon closed lid"

run_lid_closed 'b false' &&
  fail "logind recognizes an Apple Silicon open lid"
pass "logind recognizes an Apple Silicon open lid"

rm -f "$acpi_lid/macbook/state"
run_lid_closed 'b true' ||
  fail "logind remains authoritative when ACPI is absent"
pass "logind remains authoritative when ACPI is absent"
