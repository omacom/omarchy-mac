#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
acpi_lid="$test_tmp/acpi/button/lid"
dmi_chassis="$test_tmp/chassis_type"
dt_chassis="$test_tmp/dt_chassis_type"
input_class="$test_tmp/input"
mkdir -p "$stub_bin" "$acpi_lid/macbook"

cat >"$stub_bin/busctl" <<'SH'
#!/bin/bash
printf '%s\n' "${OMARCHY_TEST_LID_STATE:-b false}"
SH
chmod +x "$stub_bin/busctl"

run_laptop() {
  OMARCHY_DMI_CHASSIS_TYPE_PATH="$dmi_chassis" \
    OMARCHY_ACPI_LID_PATH="$acpi_lid" \
    OMARCHY_DT_CHASSIS_TYPE_PATH="$dt_chassis" \
    OMARCHY_INPUT_CLASS_PATH="$input_class" \
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
printf 'apple,j413\0apple,arm-platform\0' >"$test_tmp/compatible"
export OMARCHY_UNAME_M=aarch64 OMARCHY_APPLE_COMPATIBLE="$test_tmp/compatible"
printf 'laptop\0' >"$dt_chassis"
run_laptop || fail "a no-DMI Apple laptop uses firmware chassis-type"
pass "a no-DMI Apple laptop uses firmware chassis-type"
for chassis in desktop all-in-one server unknown ''; do
  printf '%s\0' "$chassis" >"$dt_chassis"
  if run_laptop; then fail "Apple identity does not override non-laptop chassis: $chassis"; fi
done
rm "$dt_chassis"
if run_laptop; then fail "a no-DMI Apple desktop with missing chassis metadata is not guessed to be a laptop"; fi
pass "no-DMI Apple desktops and unknown or missing chassis properties are not laptops"

printf 'raspberrypi,board\0' >"$test_tmp/compatible"
printf 'convertible\0' >"$dt_chassis"
run_laptop || fail "generic ARM portable firmware is recognized independently of Apple identity"
rm "$dt_chassis"
mkdir -p "$input_class/input0/capabilities"
printf '0\n' >"$input_class/input0/capabilities/sw"
if run_laptop; then fail "an input device with no SW_LID does not imply a laptop"; fi
printf '20\n' >"$input_class/input0/capabilities/sw"
if run_laptop; then fail "another input switch does not imply a lid"; fi
printf '100000000 1\n' >"$input_class/input0/capabilities/sw"
run_laptop || fail "SW_LID is detected in a multiword hexadecimal capability bitmap"
rm "$input_class/input0/capabilities/sw"
printf 'open\n' >"$acpi_lid/macbook/state"
run_laptop || fail "an ACPI lid remains a laptop signal without chassis metadata"
pass "portable chassis, actual SW_LID and ACPI lid capability work on generic hardware"

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
