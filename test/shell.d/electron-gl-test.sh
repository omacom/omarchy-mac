#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

dri="$test_tmp/dri"
mkdir -p "$dri"

if OMARCHY_DRI_PATH="$dri" "$ROOT/bin/omarchy-hw-render-gpu"; then
  fail "render GPU is absent when dri is empty"
fi
pass "render GPU is absent when dri is empty"

touch "$dri/card1"
if OMARCHY_DRI_PATH="$dri" "$ROOT/bin/omarchy-hw-render-gpu"; then
  fail "a scanout node is not a render GPU"
fi
pass "a scanout node is not a render GPU"

touch "$dri/renderD128"
OMARCHY_DRI_PATH="$dri" "$ROOT/bin/omarchy-hw-render-gpu" ||
  fail "renderD128 is a render GPU"
pass "renderD128 is a render GPU"

args=$(PATH="$ROOT/bin:$PATH" OMARCHY_DRI_PATH="$dri" \
  "$ROOT/bin/omarchy-cmd-electron-gl-args")
[[ -z $args ]] || fail "no Electron GL flags when a render GPU exists" "$args"
pass "no Electron GL flags when a render GPU exists"

rm -f "$dri/renderD128"
args=$(PATH="$ROOT/bin:$PATH" OMARCHY_DRI_PATH="$dri" \
  "$ROOT/bin/omarchy-cmd-electron-gl-args")
[[ $args == $'--ozone-platform=wayland\n--disable-gpu' ]] ||
  fail "software GL flags when no render GPU" "$args"
pass "software GL flags when no render GPU"

real="$test_tmp/real-bin"
bind="$test_tmp/bind"
mkdir -p "$bind"
printf '#!/bin/bash\nprintf "real %%s\\n" "$*"\n' >"$real"
chmod +x "$real"

PATH="$ROOT/bin:$PATH" \
  OMARCHY_ELECTRON_GL_BIND_DIR="$bind" \
  "$ROOT/bin/omarchy-cmd-electron-gl-wrap" demo "$real"

grep -q '^# omarchy-electron-gl-wrapper$' "$bind/demo" ||
  fail "wrapper is marked as an Omarchy Electron GL wrapper"
pass "wrapper is marked as an Omarchy Electron GL wrapper"

out=$(PATH="$ROOT/bin:$PATH" OMARCHY_DRI_PATH="$dri" "$bind/demo" hello)
[[ $out == "real --ozone-platform=wayland --disable-gpu hello" ]] ||
  fail "wrapper injects software GL flags" "$out"
pass "wrapper injects software GL flags"

mkdir -p "$dri"
touch "$dri/renderD128"
out=$(PATH="$ROOT/bin:$PATH" OMARCHY_DRI_PATH="$dri" "$bind/demo" hello)
[[ $out == "real hello" ]] ||
  fail "wrapper is a no-op when a render GPU exists" "$out"
pass "wrapper is a no-op when a render GPU exists"

grep -Fq 'apple/electron-gl.sh' "$ROOT/install/user/all.sh" ||
  fail "Apple Electron GL setup runs during user hardware setup"
pass "Apple Electron GL setup runs during user hardware setup"

grep -Fq 'omarchy-cmd-electron-gl-wrap' "$ROOT/bin/omarchy-install-1password" ||
  fail "1Password aarch64 installer installs the Electron GL wrapper"
pass "1Password aarch64 installer installs the Electron GL wrapper"

grep -Fq 'exec setsid uwsm-app -- 1password' "$ROOT/bin/omarchy-launch-1password" ||
  fail "1Password launcher is still the upstream uwsm-app invocation"
pass "1Password launcher is still the upstream uwsm-app invocation"

compatible="$test_tmp/compatible"
printf 'apple,j613\0apple,t8122\n' >"$compatible"
looknfeel="$test_tmp/home/.config/hypr/looknfeel.lua"
mkdir -p "$(dirname "$looknfeel")"
printf '%s\n' '-- User look and feel' >"$looknfeel"
rm -f "$dri/renderD128"

run_apple_gl() {
  HOME="$test_tmp/home" \
    PATH="$ROOT/bin:$PATH" \
    OMARCHY_DEVICE_TREE_COMPATIBLE="$compatible" \
    OMARCHY_DRI_PATH="$dri" \
    OMARCHY_CHROMIUM_BIN=/dev/null/missing \
    OMARCHY_1PASSWORD_BIN=/dev/null/missing \
    bash -euo pipefail -c 'source "$ROOT/install/user/hardware/apple/electron-gl.sh"'
}

run_apple_gl

grep -F 'no_hardware_cursors = true' "$looknfeel" >/dev/null ||
  fail "Apple Electron GL setup enables software cursors without a render GPU"
pass "Apple Electron GL setup enables software cursors without a render GPU"

run_apple_gl
(( $(grep -c 'no_hardware_cursors = true' "$looknfeel") == 1 )) ||
  fail "Apple software cursor setup is idempotent"
pass "Apple software cursor setup is idempotent"

printf '%s\n' '-- User look and feel' >"$looknfeel"
touch "$dri/renderD128"
run_apple_gl
if grep -q 'no_hardware_cursors' "$looknfeel"; then
  fail "Apple software cursors are skipped when a render GPU exists"
fi
pass "Apple software cursors are skipped when a render GPU exists"

printf 'intel,something\n' >"$compatible"
printf '%s\n' '-- User look and feel' >"$looknfeel"
rm -f "$dri/renderD128"
run_apple_gl
if grep -q 'no_hardware_cursors' "$looknfeel"; then
  fail "Apple Electron GL setup ignores non-Apple machines"
fi
pass "Apple Electron GL setup ignores non-Apple machines"

migration=$(grep -rl 'Wrap Electron apps when Apple Silicon has no render GPU' "$ROOT/migrations" | head -n 1 || true)
[[ -n $migration ]] || fail "existing installs get the Electron GL wrapper migration"
pass "existing installs get the Electron GL wrapper migration"
