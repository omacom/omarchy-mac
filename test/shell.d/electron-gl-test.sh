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

# A repeated user finalization must not chmod an already-correct system wrapper.
stubs="$test_tmp/stubs"
mkdir -p "$stubs"
cat >"$stubs/chmod" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_PERMISSION_CALLS"
[[ ${OMARCHY_TEST_ALLOW_CHMOD:-0} == "1" ]] || exit 91
exec /usr/bin/chmod "$@"
STUB
cat >"$stubs/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$OMARCHY_TEST_PERMISSION_CALLS"
exit 92
STUB
chmod +x "$stubs/chmod" "$stubs/sudo"
permission_calls="$test_tmp/permission-calls"
run_wrap() {
  PATH="$stubs:$ROOT/bin:$PATH" \
    OMARCHY_TEST_PERMISSION_CALLS="$permission_calls" \
    OMARCHY_ELECTRON_GL_BIND_DIR="$bind" \
    "$ROOT/bin/omarchy-cmd-electron-gl-wrap" demo "$real"
}

chmod 555 "$bind"
run_wrap || fail "correct wrapper needs no privilege or permission changes on repeat"
chmod 755 "$bind"
[[ ! -e $permission_calls ]] ||
  fail "correct wrapper must not invoke chmod or sudo"
pass "correct wrapper needs no privilege or permission changes on repeat"

for mode in 644 775; do
  chmod "$mode" "$bind/demo"
  OMARCHY_TEST_ALLOW_CHMOD=1 run_wrap ||
    fail "wrapper repairs incorrect mode $mode"
  [[ $(stat -c %a "$bind/demo") == "755" ]] ||
    fail "wrapper restores mode 755 from $mode"
done
pass "wrapper repairs missing execute and excessive write permissions"

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
