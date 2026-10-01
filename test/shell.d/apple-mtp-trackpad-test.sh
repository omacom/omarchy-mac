#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/fix-mtp-trackpad.sh"
all="$ROOT/install/hardware/all.sh"
migration="$ROOT/migrations/1789705790.sh"

grep -Fq 'apple/fix-mtp-trackpad.sh' "$all" ||
  fail "the MTP trackpad quirk runs during hardware setup"
[[ -f $migration ]] || fail "existing installs get the MTP trackpad quirk"
grep -Fq 'fix-mtp-trackpad.sh' "$migration" ||
  fail "the migration runs the same hardware leaf"
grep -Fq 'disable_while_typing = true' "$ROOT/default/hypr/input.lua" ||
  fail "Hyprland defaults keep disable-while-typing on"
pass "fresh and existing installs are wired to the MTP trackpad quirk"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

quirks_dir="$test_tmp/libinput"
input_root="$test_tmp/input"
compatible="$test_tmp/compatible"
stub_bin="$test_tmp/bin"
mkdir -p "$quirks_dir" "$input_root/event2/device" "$stub_bin"
printf 'apple,j416c\0apple,t6021\0apple,arm-platform\0' >"$compatible"
printf 'Apple MTP multi-touch\n' >"$input_root/event2/device/name"

cat >"$stub_bin/udevadm" <<'SH'
#!/bin/bash
# Property lookup is on the event node, not the parent inputN.
if [[ $1 == info && $2 == -q && $3 == property && $4 == -p && $5 == *"/event2" ]]; then
  printf 'ID_INPUT_WIDTH_MM=157\nID_INPUT_HEIGHT_MM=96\n'
  exit 0
fi
exit 1
SH
chmod +x "$stub_bin/udevadm"

run_leaf() {
  rm -f "$quirks_dir/omarchy-apple-mtp.quirks"
  OMARCHY_LIBINPUT_QUIRKS_DIR="$quirks_dir" \
    OMARCHY_INPUT_SYSFS="$input_root" \
    OMARCHY_APPLE_COMPATIBLE="$compatible" \
    OMARCHY_TEST_ARCH="${1:-aarch64}" \
    OMARCHY_APPLE_MTP_WIDTH_MM="${2-}" \
    OMARCHY_APPLE_MTP_HEIGHT_MM="${3-}" \
    PATH="$stub_bin:$PATH" \
    bash -eE -c 'source "$1"' bash "$leaf"
}

run_leaf aarch64 157 96
quirks="$quirks_dir/omarchy-apple-mtp.quirks"
[[ -f $quirks ]] || fail "the leaf writes a libinput override on Apple Silicon"
grep -Fq 'MatchName=Apple MTP keyboard' "$quirks" ||
  fail "the keyboard is marked internal without MatchVendor"
grep -Fq 'AttrKeyboardIntegration=internal' "$quirks" ||
  fail "the keyboard is marked internal for disable-while-typing"
grep -Fq 'MatchName=Apple MTP multi-touch' "$quirks" ||
  fail "the override targets the Asahi MTP touchpad name"
grep -Fq 'AttrPalmSizeThreshold=1600' "$quirks" ||
  fail "the override uses the libinput palm-size attribute spelling"
if grep -q 'AttrPalmSizeTreshold' "$quirks"; then
  fail "the override must not use the AttrPalmSizeTreshold typo"
fi
if grep -q '^MatchVendor=' "$quirks"; then
  fail "the override must not require ID_VENDOR, which Asahi platform devices omit"
fi
grep -Fq 'AttrSizeHint=157x96' "$quirks" ||
  fail "the override replaces the 13-inch 104x75 hint with the measured pad" "$(cat "$quirks")"
if grep -q '104x75' "$quirks"; then
  fail "the override must not keep the 13-inch size hint"
fi
pass "the MTP override measures the pad and marks the keyboard internal"

run_leaf x86_64 157 96
[[ ! -e $quirks ]] || fail "the leaf skips non-aarch64 machines"
pass "the MTP override skips Intel machines"

printf 'linux,dummy\n' >"$compatible"
run_leaf aarch64 157 96
[[ ! -e $quirks ]] || fail "the leaf skips non-Apple aarch64"
pass "the MTP override skips non-Apple aarch64"

printf 'apple,j413\0' >"$compatible"
# Hide the event node so udevadm has nothing to measure.
rm -rf "$input_root/event2"
run_leaf aarch64
[[ -f $quirks ]] || fail "the leaf still writes keyboard integration without a measured size"
if grep -q 'AttrSizeHint=' "$quirks"; then
  fail "no AttrSizeHint is written when the pad size is unknown" "$(cat "$quirks")"
fi
grep -Fq 'AttrKeyboardIntegration=internal' "$quirks" ||
  fail "keyboard integration is still written without a measured size"
pass "the leaf writes keyboard integration even when pad size is unknown"

mkdir -p "$input_root/event2/device"
printf 'Apple MTP multi-touch\n' >"$input_root/event2/device/name"
printf 'apple,j416c\0' >"$compatible"
run_leaf aarch64
grep -Fq 'AttrSizeHint=157x96' "$quirks" ||
  fail "udevadm size on the event node becomes AttrSizeHint" "$(cat "$quirks")"
pass "the leaf reads pad size from udev on the event node"
