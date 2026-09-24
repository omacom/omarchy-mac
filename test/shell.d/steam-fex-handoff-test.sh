#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

[[ ! -e $ROOT/bin/omarchy-launch-steam ]] || fail "omarchy no longer owns the Steam launcher supplied by omarchy-steam-fex"
pass "omarchy no longer owns the Steam launcher"
"$ROOT/bin/omarchy" commands --json | jq -e '.commands[] | select(.route == "omarchy launch steam" and .binary == "omarchy-launch-fex-steam")' >/dev/null ||
  fail "omarchy launch steam still routes to the external launcher"
pass "omarchy launch steam route remains available"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin" "$test_tmp/home/.local/share/applications"
export HOME="$test_tmp/home"
export OMARCHY_TEST_LOG="$test_tmp/calls"
export PATH="$test_tmp/bin:$ROOT/bin:$PATH"

cat >"$test_tmp/bin/uname" <<'SH'
#!/bin/bash
if [[ ${1:-} == "-m" ]]; then
  echo "${OMARCHY_TEST_ARCH:-aarch64}"
else
  /usr/bin/uname "$@"
fi
SH
for command in omarchy-pkg-add omarchy-pkg-drop omarchy-launch-steam omarchy-install-gaming-gpu-lib32 steam; do
  cat >"$test_tmp/bin/$command" <<'SH'
#!/bin/bash
printf '%s:%s\n' "${0##*/}" "$*" >>"$OMARCHY_TEST_LOG"
SH
done
cat >"$test_tmp/bin/omarchy-pkg-present" <<'SH'
#!/bin/bash
for package in "$@"; do
  [[ $package != "steam" || ${OMARCHY_TEST_STEAM_MISSING:-0} != "1" ]] || exit 1
  [[ $package != "omarchy-steam-fex" || ${OMARCHY_TEST_FEX_MISSING:-0} != "1" ]] || exit 1
done
SH
cat >"$test_tmp/bin/pacman" <<'SH'
#!/bin/bash
[[ ${1:-} == "-Si" ]] || exit 1
[[ ${2:-} != "omarchy-steam-fex" || ${OMARCHY_TEST_FEX_UNAVAILABLE:-0} != "1" ]]
SH
cat >"$test_tmp/bin/setsid" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$test_tmp/bin"/*

omarchy-pkg-available omarchy-steam-fex || fail "the FEX launcher is available from the configured repository"
if OMARCHY_TEST_FEX_UNAVAILABLE=1 omarchy-pkg-available omarchy-steam-fex; then
  fail "the availability helper rejects a missing FEX package"
fi
pass "package availability tracks the configured repository"

bash "$ROOT/bin/omarchy-launch-fex-steam" 'steam://open test'
grep -Fxq 'omarchy-launch-steam:steam://open test' "$OMARCHY_TEST_LOG" || fail "Steam route delegates to the FEX launcher on aarch64"
OMARCHY_TEST_ARCH=x86_64 bash "$ROOT/bin/omarchy-launch-fex-steam" 'steam://open test'
grep -Fxq 'steam:steam://open test' "$OMARCHY_TEST_LOG" || fail "Steam route delegates to Steam on other architectures"
pass "Steam route retains platform-specific launch behavior"

bash "$ROOT/bin/omarchy-install-gaming-steam"
grep -Fxq 'omarchy-pkg-add:omarchy-steam-fex' "$OMARCHY_TEST_LOG" || fail "Steam installer installs the FEX launcher package"
grep -Fxq 'omarchy-launch-steam:--prepare' "$OMARCHY_TEST_LOG" || fail "Steam installer prepares the packaged launcher"
pass "Steam installer installs and prepares the FEX launcher"

: >"$OMARCHY_TEST_LOG"
if OMARCHY_TEST_FEX_MISSING=1 bash "$ROOT/bin/omarchy-install-gaming-steam"; then
  fail "Steam installer rejects a missing FEX launcher package"
fi
if grep -q '^omarchy-launch-steam:' "$OMARCHY_TEST_LOG"; then
  fail "Steam installer does not prepare a missing launcher"
fi
pass "Steam installer rejects an unavailable FEX launcher"

: >"$OMARCHY_TEST_LOG"
if OMARCHY_TEST_FEX_MISSING=1 OMARCHY_TEST_FEX_UNAVAILABLE=1 bash "$ROOT/bin/omarchy-install-gaming-steam"; then
  fail "Steam installer rejects a FEX package absent from the repository"
fi
if grep -q '^omarchy-pkg-add:steam' "$OMARCHY_TEST_LOG"; then
  fail "Steam installer checks FEX availability before installing Steam"
fi
pass "Steam installer avoids a partial install when FEX is unavailable"

steam_guard=$(node - "$ROOT" <<'JS'
const fs = require('fs')
const path = require('path')
const root = process.argv[2]
const menu = require(path.join(root, 'shell/plugins/menu/MenuModel.js'))
const items = menu.parseMenuJsonc(fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8'))
process.stdout.write(items.find(item => item.id === 'install.gaming.steam').disabled)
JS
)
if OMARCHY_TEST_FEX_MISSING=1 bash -c "$steam_guard"; then
  fail "Steam Install row stays available after a failed FEX install"
fi
bash -c "$steam_guard" || fail "Steam Install row disables after both packages install"
OMARCHY_TEST_ARCH=x86_64 OMARCHY_TEST_FEX_MISSING=1 bash -c "$steam_guard" ||
  fail "Steam Install row remains disabled off aarch64 when Steam is installed"
if OMARCHY_TEST_STEAM_MISSING=1 bash -c "$steam_guard"; then
  fail "Steam Install row is available when Steam is missing"
fi
pass "Steam Install row reflects both required packages on Apple Silicon"

steam_visibility=$(node - "$ROOT" <<'JS'
const fs = require('fs')
const path = require('path')
const root = process.argv[2]
const menu = require(path.join(root, 'shell/plugins/menu/MenuModel.js'))
const items = menu.parseMenuJsonc(fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8'))
process.stdout.write(items.find(item => item.id === 'install.gaming.steam').when)
JS
)
OMARCHY_TEST_FEX_MISSING=1 bash -c "$steam_visibility" || fail "Steam Install row appears when FEX is available"
if OMARCHY_TEST_FEX_MISSING=1 OMARCHY_TEST_FEX_UNAVAILABLE=1 bash -c "$steam_visibility"; then
  fail "Steam Install row hides when FEX is unavailable"
fi
OMARCHY_TEST_ARCH=x86_64 OMARCHY_TEST_FEX_MISSING=1 OMARCHY_TEST_FEX_UNAVAILABLE=1 bash -c "$steam_visibility" ||
  fail "Steam Install row remains available off aarch64"
pass "Steam Install row respects FEX repository availability"

: >"$OMARCHY_TEST_LOG"
OMARCHY_TEST_FEX_MISSING=1 bash "$ROOT/migrations/1787606800.sh"
if grep -q '^omarchy-launch-steam:' "$OMARCHY_TEST_LOG"; then
  fail "older Steam migration does not run a launcher before the handoff"
fi
pass "older Steam migration defers launcher setup"

: >"$OMARCHY_TEST_LOG"
bash "$ROOT/migrations/1787606800.sh"
grep -Fxq 'omarchy-launch-steam:--prepare' "$OMARCHY_TEST_LOG" || fail "older Steam migration still prepares an installed launcher"
pass "older Steam migration retains its installed-launcher behavior"

: >"$OMARCHY_TEST_LOG"
if OMARCHY_TEST_FEX_MISSING=1 bash "$ROOT/migrations/1790281735.sh"; then
  fail "Steam handoff rejects a missing FEX launcher package"
fi
if grep -q '^omarchy-launch-steam:' "$OMARCHY_TEST_LOG"; then
  fail "Steam handoff does not prepare a missing launcher"
fi
pass "Steam handoff rejects an unavailable FEX launcher"

: >"$OMARCHY_TEST_LOG"
bash "$ROOT/migrations/1790281735.sh"
grep -Fxq 'omarchy-pkg-add:omarchy-steam-fex' "$OMARCHY_TEST_LOG" || fail "Steam handoff migrates existing users"
grep -Fxq 'omarchy-launch-steam:--prepare' "$OMARCHY_TEST_LOG" || fail "Steam handoff prepares the packaged launcher"
pass "Steam handoff migrates existing users"

: >"$OMARCHY_TEST_LOG"
bash "$ROOT/bin/omarchy-remove-gaming-steam"
grep -Fxq 'omarchy-pkg-drop:omarchy-steam-fex steam' "$OMARCHY_TEST_LOG" || fail "Steam removal drops the dependent FEX launcher with Steam"
pass "Steam removal drops the FEX launcher with Steam"
