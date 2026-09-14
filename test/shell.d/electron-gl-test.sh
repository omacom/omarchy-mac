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

wrap() {
  PATH="$ROOT/bin:$PATH" OMARCHY_ELECTRON_GL_BIND_DIR="$bind" \
    "$ROOT/bin/omarchy-cmd-electron-gl-wrap" "$@"
}

# Recognize only the legacy 1Password link, using the setup leaf's binary override
# so this exercises the unmodified helper without writing to /opt.
legacy_real="$test_tmp/1Password/1password"
mkdir -p "$(dirname "$legacy_real")"
cp "$real" "$legacy_real"
chmod 751 "$legacy_real"
legacy_hash=$(sha256sum "$legacy_real")
ln -s "$legacy_real" "$bind/1password"
if wrap 1password "$legacy_real" 2>"$test_tmp/error"; then
  fail "default legacy exception must refuse an arbitrary 1Password target"
fi
OMARCHY_1PASSWORD_BIN="$legacy_real" wrap 1password "$legacy_real" ||
  fail "known legacy 1Password symlink can be migrated"
[[ ! -L $bind/1password && -f $bind/1password ]] ||
  fail "legacy symlink is replaced with a regular wrapper"
[[ $(sha256sum "$legacy_real") == "$legacy_hash" && $(stat -c %a "$legacy_real") == "751" ]] ||
  fail "legacy migration preserves the real binary bytes and permissions"
out=$(PATH="$ROOT/bin:$PATH" OMARCHY_DRI_PATH="$dri" "$bind/1password" "vault with spaces")
[[ $out == "real vault with spaces" ]] || fail "migrated 1Password wrapper executes the real binary" "$out"
legacy_wrapper_hash=$(sha256sum "$bind/1password")
OMARCHY_1PASSWORD_BIN="$legacy_real" wrap 1password "$legacy_real"
[[ $(sha256sum "$bind/1password") == "$legacy_wrapper_hash" ]] ||
  fail "legacy migration is idempotent"
pass "legacy 1Password migration preserves and executes the real binary, and is idempotent"

rm "$bind/1password"
ln -s "$legacy_real" "$bind/1password"
OMARCHY_1PASSWORD_INSTALL_DIR="$(dirname "$legacy_real")" wrap 1password "$legacy_real" ||
  fail "legacy migration honors the installer's configured directory"
[[ ! -L $bind/1password && $(sha256sum "$legacy_real") == "$legacy_hash" ]] ||
  fail "configured install-directory migration replaces only the link"
pass "legacy migration honors the installer's configured directory"

other_real="$test_tmp/other-real"
cp "$real" "$other_real"
wrap demo "$other_real"
grep -Fxq "real=$other_real" "$bind/demo" || fail "marked wrapper can be updated to another binary"
pass "marked regular wrappers can be updated"

printf '#!/bin/bash\nprintf custom\\n\n' >"$bind/chromium"
chmod 750 "$bind/chromium"
custom_hash=$(sha256sum "$bind/chromium")
if wrap chromium "$real" 2>"$test_tmp/error"; then
  fail "custom Chromium launcher must be refused"
fi
[[ $(sha256sum "$bind/chromium") == "$custom_hash" && $(stat -c %a "$bind/chromium") == "750" ]] ||
  fail "custom Chromium launcher bytes and permissions are preserved"
grep -Fq 'unmanaged launcher' "$test_tmp/error" || fail "custom launcher refusal explains the conflict"
pass "custom Chromium launcher is refused and preserved"

for link_target in "$other_real" "$test_tmp/missing" "$bind/demo"; do
  ln -s "$link_target" "$bind/unknown"
  if wrap unknown "$real" 2>"$test_tmp/error"; then
    fail "unknown symlink must be refused" "$link_target"
  fi
  [[ -L $bind/unknown && $(readlink "$bind/unknown") == "$link_target" ]] ||
    fail "unknown symlink is preserved" "$link_target"
  rm "$bind/unknown"
done
pass "unknown, dangling, and marked-wrapper symlinks are refused and preserved"

ln -s "$other_real" "$bind/1password-other"
if OMARCHY_1PASSWORD_BIN="$other_real" wrap 1password-other "$other_real" 2>"$test_tmp/error"; then
  fail "legacy exception requires the 1password command name"
fi
rm "$bind/1password"
ln -s "$other_real" "$bind/1password"
if OMARCHY_1PASSWORD_BIN="$legacy_real" wrap 1password "$other_real" 2>"$test_tmp/error"; then
  fail "legacy exception requires the configured 1Password binary"
fi
[[ $(readlink "$bind/1password") == "$other_real" ]] || fail "unknown 1Password link is preserved"
pass "legacy exception requires both the known command name and binary"

cp "$real" "$bind/self"
self_hash=$(sha256sum "$bind/self")
if wrap self "$bind/self" 2>"$test_tmp/error"; then
  fail "literal self-wrap must be refused"
fi
[[ $(sha256sum "$bind/self") == "$self_hash" ]] || fail "self-wrap preserves real executable"
ln "$real" "$bind/hardlink"
if wrap hardlink "$real" 2>"$test_tmp/error"; then
  fail "hardlink self-wrap must be refused"
fi
[[ $bind/hardlink -ef $real ]] || fail "hardlink self-wrap preserves hardlink"
# The legacy exception applies to symlinks, never hardlinked 1Password binaries.
rm "$bind/1password"
ln "$legacy_real" "$bind/1password"
if OMARCHY_1PASSWORD_BIN="$legacy_real" wrap 1password "$legacy_real" 2>"$test_tmp/error"; then
  fail "hardlinked 1Password binary must be refused"
fi
[[ $(sha256sum "$legacy_real") == "$legacy_hash" && $(stat -c %a "$legacy_real") == "751" ]] ||
  fail "hardlink self-wrap preserves binary bytes and mode"
pass "literal self-wrap and hardlinked binaries are refused"

for invalid_name in "" . .. ../escape nested/launcher; do
  if wrap "$invalid_name" "$real" 2>"$test_tmp/error"; then
    fail "command name must be a basename" "$invalid_name"
  fi
done
[[ ! -e $test_tmp/escape && ! -e $bind/nested ]] || fail "invalid names do not escape the launcher directory"
pass "invalid and traversing command names are refused"

# Fail after staging has begun: neither an old wrapper nor the legacy symlink
# may be replaced until both the staged write and permissions have succeeded.
failure_stubs="$test_tmp/failure-stubs"
mkdir -p "$failure_stubs"
for command in mktemp tee chmod mv; do
  printf '#!/bin/bash\nexit 93\n' >"$failure_stubs/$command"
  chmod +x "$failure_stubs/$command"
  for launcher in demo 1password; do
    rm -f "$bind/1password"
    ln -s "$legacy_real" "$bind/1password"
    old_wrapper_hash=$(sha256sum "$bind/demo")
    if [[ $launcher == "1password" ]]; then
      target_real=$legacy_real
    else
      target_real=$real
    fi
    if PATH="$failure_stubs:$ROOT/bin:$PATH" \
      OMARCHY_ELECTRON_GL_BIND_DIR="$bind" OMARCHY_1PASSWORD_BIN="$legacy_real" \
      "$ROOT/bin/omarchy-cmd-electron-gl-wrap" "$launcher" "$target_real" \
      2>"$test_tmp/error"; then
      fail "failed staging $command must be reported for $launcher"
    fi
    [[ $(sha256sum "$bind/demo") == "$old_wrapper_hash" ]] || fail "failed $command preserves old wrapper"
    [[ -L $bind/1password && $(readlink "$bind/1password") == "$legacy_real" ]] ||
      fail "failed $command preserves legacy symlink"
    [[ $(sha256sum "$legacy_real") == "$legacy_hash" && $(stat -c %a "$legacy_real") == "751" ]] ||
      fail "failed $command preserves real binary bytes and mode"
    if compgen -G "$bind/.omarchy-electron-gl.*" >/dev/null; then
      fail "failed $command cleans up staged files"
    fi
  done
  rm "$failure_stubs/$command"
done
pass "mktemp, write, chmod, and rename failures preserve launchers and clean up staged files"

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
