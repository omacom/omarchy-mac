#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/touchbar.sh"
all="$ROOT/install/hardware/all.sh"
conf="$ROOT/default/tiny-dfr/config.toml"
plugin="$ROOT/shell/plugins/touchbar"
apply="$plugin/apply.sh"
omarchy_lua="$ROOT/default/hypr/omarchy.lua"
binds="$ROOT/default/hypr/bindings/touchbar.lua"
migration=$(grep -rl 'Put Omarchy actions on the Apple Silicon Touch Bar' "$ROOT/migrations" | head -n 1 || true)

[[ -f $leaf ]] || fail "the Apple Silicon Touch Bar setup leaf ships"
[[ -f $conf ]] || fail "the default tiny-dfr layout ships"
[[ -f $plugin/manifest.json ]] || fail "omarchy.touchbar ships"
grep -q '"id": "omarchy.touchbar"' "$plugin/manifest.json" ||
  fail "the Touch Bar plugin uses the first-party namespace"
grep -Fq 'apple/touchbar.sh' "$all" ||
  fail "Touch Bar setup runs during hardware setup"
grep -Fq 'default.hypr.bindings.touchbar' "$omarchy_lua" ||
  fail "Hyprland loads Touch Bar key bindings"
grep -Fq 'XF86Search' "$binds" || fail "Search on the Touch Bar opens the Omarchy menu"
grep -Fq 'omarchy-launch-terminal' "$binds" || fail "F13 launches a terminal"
grep -Fq 'omarchy-system-lock' "$binds" || fail "F14 locks the session"
grep -q 'MediaLayerDefault = true' "$conf" ||
  fail "the default strip is the Omarchy/media layer without holding Fn"
grep -q 'Action = "Search"' "$conf" || fail "the default strip includes the menu key"
[[ -n $migration ]] || fail "existing Apple Silicon installs get the Touch Bar layout"
pass "fresh and existing installs are wired to the Apple Silicon Touch Bar"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
compatible="$test_tmp/compatible"
conf_dst="$test_tmp/etc/tiny-dfr/config.toml"
mkdir -p "$stub_bin" "$(dirname "$conf_dst")"

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash

if [[ ${1:-} == "-m" ]]; then
  printf '%s\n' "$TEST_ARCH"
else
  exec /usr/bin/uname "$@"
fi
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

printf 'sudo' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
"$@"
SH

cat >"$stub_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash

[[ ! -e $TINY_DFR_INSTALLED ]]
SH

cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash

printf 'omarchy-pkg-add' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
touch "$TINY_DFR_INSTALLED"
SH

cat >"$stub_bin/systemctl" <<'SH'
#!/bin/bash

printf 'systemctl' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
SH

chmod +x "$stub_bin"/*

run_leaf() {
  local arch=$1 machine=$2
  printf '%s\0' "$machine" >"$compatible"
  PATH="$stub_bin:$PATH" \
    TEST_ARCH="$arch" \
    TEST_LOG="$calls" \
    TINY_DFR_INSTALLED="$test_tmp/tiny-dfr-installed" \
    OMARCHY_APPLE_COMPATIBLE="$compatible" \
    OMARCHY_TINY_DFR_CONF="$conf_dst" \
    OMARCHY_PATH="$ROOT" \
    bash -euo pipefail -c 'source "$1"' bash "$leaf" >/dev/null
}

: >"$calls"
run_leaf x86_64 apple,j293
[[ ! -e $conf_dst ]] || fail "Intel Macs do not take the Asahi tiny-dfr layout"
pass "non-aarch64 machines skip Touch Bar setup"

: >"$calls"
run_leaf aarch64 raspberrypi,4
[[ ! -e $conf_dst ]] || fail "non-Apple aarch64 skips Touch Bar setup"
pass "non-Apple aarch64 skips Touch Bar setup"

: >"$calls"
run_leaf aarch64 apple,j293
[[ -f $conf_dst ]] || fail "Apple Silicon installs the tiny-dfr layout"
grep -q 'Omarchy Apple Silicon Touch Bar' "$conf_dst" ||
  fail "the installed config is the Omarchy layout"
grep -Fxq $'omarchy-pkg-add\ttiny-dfr' "$calls" ||
  fail "Apple Silicon gets tiny-dfr when it is missing" "$(cat "$calls")"
pass "Apple Silicon installs tiny-dfr and the Omarchy Touch Bar layout"

run_leaf aarch64 apple,j293
(( $(grep -Fxc $'omarchy-pkg-add\ttiny-dfr' "$calls") == 1 )) ||
  fail "Touch Bar package install is idempotent" "$(cat "$calls")"
pass "Touch Bar setup is idempotent"

printf 'user hand-written tiny-dfr config\n' >"$conf_dst"
: >"$calls"
run_leaf aarch64 apple,j293
grep -q 'user hand-written' "$conf_dst" ||
  fail "a custom tiny-dfr config is left alone"
pass "a custom tiny-dfr config is left alone"

toml=$(OMARCHY_TOUCHBAR_SKIP_INSTALL=1 OMARCHY_TOUCHBAR_TOML="$test_tmp/out.toml" \
  bash "$apply")
grep -q 'MediaLayerDefault = true' "$toml" ||
  fail "apply.sh renders the stock layout"
pass "apply.sh renders the stock layout"

printf '{"mediaLayerDefault": false, "buttons": [{"text": "x", "key": "F20"}], "fnLayer": [{"text": "F1", "key": "F1"}]}\n' \
  >"$test_tmp/overlay.json"
toml=$(OMARCHY_TOUCHBAR_SKIP_INSTALL=1 \
  OMARCHY_TOUCHBAR_LAYOUT="$test_tmp/overlay.json" \
  OMARCHY_TOUCHBAR_TOML="$test_tmp/overlay.toml" \
  bash "$apply")
grep -q 'MediaLayerDefault = false' "$toml" ||
  fail "apply.sh honours a user overlay"
grep -q 'Action = "F20"' "$toml" || fail "apply.sh renders overlay buttons"
pass "apply.sh honours a user overlay"
