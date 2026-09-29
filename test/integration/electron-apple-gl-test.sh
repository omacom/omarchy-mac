#!/bin/bash
# omarchy-mac's Electron GL setup, run as the runtime's user hardware setup runs it
# on an Apple Silicon Mac without a render GPU.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

dri="$test_tmp/dri"
mkdir -p "$dri"

grep -Fq 'user/platform-setup.sh' "$ROOT/install/user/all.sh" && [[ -x $MAC/lib/electron-desktop-entries ]] ||
  fail "Apple Electron GL setup runs during user hardware setup, through omarchy-mac"
pass "Apple Electron GL setup runs during user hardware setup, through omarchy-mac"

compatible="$test_tmp/compatible"
printf 'apple,j613\0apple,t8122\n' >"$compatible"
looknfeel="$test_tmp/home/.config/hypr/looknfeel.lua"
mkdir -p "$(dirname "$looknfeel")"
printf '%s\n' '-- User look and feel' >"$looknfeel"
rm -f "$dri/renderD128"

apple_stub="$test_tmp/apple-stub"
mkdir -p "$apple_stub"
cat >"$apple_stub/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
[[ -f ${OMARCHY_DEVICE_TREE_COMPATIBLE:-} ]] && grep -qi apple "$OMARCHY_DEVICE_TREE_COMPATIBLE"
SH
cat >"$apple_stub/omarchy-hw-platform" <<'SH'
#!/bin/bash
if omarchy-hw-apple-silicon; then echo apple-silicon; else echo generic; fi
SH
chmod +x "$apple_stub/omarchy-hw-apple-silicon" "$apple_stub/omarchy-hw-platform"

run_apple_gl() {
  HOME="$test_tmp/home" \
    PATH="$apple_stub:$ROOT/bin:$PATH" \
    OMARCHY_DEVICE_TREE_COMPATIBLE="$compatible" \
    OMARCHY_DRI_PATH="$dri" \
    OMARCHY_CHROMIUM_BIN=/dev/null/missing \
    OMARCHY_1PASSWORD_BIN=/dev/null/missing \
    OMARCHY_CURSOR_BIN=/dev/null/missing \
    "$MAC/lib/electron-desktop-entries"
}

run_apple_gl
if grep -q 'no_hardware_cursors' "$looknfeel"; then
  fail "Apple Electron GL setup leaves the software cursor to omarchy-mac"
fi
pass "Apple Electron GL setup leaves the software cursor to omarchy-mac"
