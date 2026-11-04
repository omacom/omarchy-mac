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
quirks="$quirks_dir/local-overrides.quirks"
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
[[ -f $quirks ]] || fail "the leaf writes a libinput override on Apple Silicon"
[[ ! -e $quirks_dir/omarchy-apple-mtp.quirks ]] ||
  fail "the leaf uses libinput's supported local override filename"
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

# Re-running must not replace the file when its managed content is unchanged.
cp "$quirks" "$test_tmp/first-run.quirks"
first_inode=$(stat -c %i "$quirks")
run_leaf aarch64 157 96
cmp -s "$quirks" "$test_tmp/first-run.quirks" ||
  fail "a repeated run leaves the generated file identical"
[[ $(stat -c %i "$quirks") == "$first_inode" ]] ||
  fail "an unchanged override is not rewritten"
pass "the MTP override is idempotent"

# The user may have matching overrides, unrelated sections, a private mode and
# no final newline. Keep those bytes intact after the managed block so their
# matching properties remain the last values libinput sees.
printf '# Custom settings\n\n[Administrator MTP]\nMatchName=Apple MTP multi-touch\nMatchUdevType=touchpad\nAttrPalmSizeThreshold=1800\nAttrSizeHint=123x77\n\n[Administrator keyboard]\nMatchName=Some other keyboard\nMatchUdevType=keyboard\nAttrKeyboardIntegration=external' >"$test_tmp/admin.quirks"
cp "$test_tmp/admin.quirks" "$quirks"
chmod 640 "$quirks"
printf 'An ignored custom file\n' >"$quirks_dir/omarchy-apple-mtp.quirks"
run_leaf aarch64 157 96
python3 - "$quirks" "$test_tmp/admin.quirks" <<'PY'
from pathlib import Path
import sys

generated, administrator = (Path(path).read_bytes() for path in sys.argv[1:])
end = b"# END OMARCHY APPLE MTP QUIRKS\n"
assert generated.endswith(administrator), "administrator bytes were modified"
assert generated.split(end, 1)[1] == administrator, "administrator sections do not follow the managed block"
assert generated.count(b"# BEGIN OMARCHY APPLE MTP QUIRKS\n") == 1
assert generated.index(b"AttrPalmSizeThreshold=1600") < generated.index(b"AttrPalmSizeThreshold=1800")
assert generated.index(b"AttrSizeHint=157x96") < generated.index(b"AttrSizeHint=123x77")
PY
[[ $(stat -c %a "$quirks") == "640" ]] || fail "administrator permissions are preserved"
[[ $(cat "$quirks_dir/omarchy-apple-mtp.quirks") == "An ignored custom file" ]] ||
  fail "the leaf must not overwrite an arbitrary legacy-named file"
pass "administrator content, permissions and matching overrides are preserved"

cp "$quirks" "$test_tmp/admin-combined.quirks"
run_leaf aarch64 157 96
cmp -s "$quirks" "$test_tmp/admin-combined.quirks" ||
  fail "replacing the managed block preserves administrator content idempotently"
pass "managed-block replacement is idempotent with administrator overrides"

# A linked local-overrides.quirks remains a link to the administrator's file.
mv "$quirks" "$test_tmp/linked.quirks"
ln -s "$test_tmp/linked.quirks" "$quirks"
run_leaf aarch64 158 97
[[ -L $quirks ]] || fail "an administrator's override symlink is preserved"
grep -Fq 'AttrSizeHint=158x97' "$test_tmp/linked.quirks" ||
  fail "the managed block is updated through the preserved symlink"
[[ $(stat -c %a "$test_tmp/linked.quirks") == "640" ]] ||
  fail "linked override permissions are preserved"
pass "linked administrator overrides are preserved"

# Unbalanced markers must fail before modifying the user's file.
rm "$quirks"
printf '# BEGIN OMARCHY APPLE MTP QUIRKS\n# Custom content\n' >"$quirks"
cp "$quirks" "$test_tmp/ambiguous.quirks"
if run_leaf aarch64 157 96 >"$test_tmp/ambiguous.log" 2>&1; then
  fail "an unterminated managed block must not be replaced"
fi
cmp -s "$quirks" "$test_tmp/ambiguous.quirks" ||
  fail "an unterminated managed block leaves the file unchanged"
pass "ambiguous managed markers leave administrator content untouched"

rm "$quirks"
run_leaf x86_64 157 96
[[ ! -e $quirks ]] || fail "the leaf skips non-aarch64 machines"
pass "the MTP override skips Intel machines"

cp "$test_tmp/admin.quirks" "$quirks"
run_leaf x86_64 157 96
cmp -s "$quirks" "$test_tmp/admin.quirks" ||
  fail "the leaf leaves existing Intel-machine overrides untouched"
rm "$quirks"
printf 'linux,dummy\n' >"$compatible"
run_leaf aarch64 157 96
[[ ! -e $quirks ]] || fail "the leaf skips non-Apple aarch64"
pass "the MTP override skips non-Apple aarch64"

cp "$test_tmp/admin.quirks" "$quirks"
run_leaf aarch64 157 96
cmp -s "$quirks" "$test_tmp/admin.quirks" ||
  fail "the leaf leaves existing non-Apple overrides untouched"
rm "$quirks"
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

for dimensions in "0 96" "157 0" "0 0" "00 00"; do
  read -r width height <<<"$dimensions"
  run_leaf aarch64 "$width" "$height"
  if grep -q 'AttrSizeHint=' "$quirks"; then
    fail "zero dimensions must not produce a libinput-invalid size hint" "$(cat "$quirks")"
  fi
done
pass "zero dimensions remove the managed size hint without invalidating the quirks"

# Validate the exact file through libinput's parser when its debug utilities
# are installed. --data-dir keeps this check entirely inside the fixture.
validator_dir="$test_tmp/validate"
mkdir "$validator_dir"
validate_quirks() {
  cp "$quirks" "$validator_dir/local-overrides.quirks"
  if [[ -n ${OMARCHY_TEST_LIBINPUT_QUIRKS:-} ]]; then
    "$OMARCHY_TEST_LIBINPUT_QUIRKS" validate --data-dir "$validator_dir"
  else
    libinput quirks validate --data-dir "$validator_dir"
  fi
}

if [[ -n ${OMARCHY_TEST_LIBINPUT_QUIRKS:-} ]] || command -v libinput >/dev/null; then
  validate_quirks || fail "libinput accepts the override with zero dimensions omitted"
  run_leaf aarch64 157 96
  validate_quirks || fail "libinput accepts the measured-size override"
  cp "$test_tmp/admin-combined.quirks" "$quirks"
  validate_quirks || fail "libinput accepts the preserved administrator overrides"
  rm -rf "$input_root/event2"
  run_leaf aarch64
  validate_quirks || fail "libinput accepts the override without measured dimensions"
  pass "libinput's parser validates zero-size, measured, administrator and unknown-size overrides"
else
  pass "libinput debug utilities unavailable; skipping parser validation"
fi
