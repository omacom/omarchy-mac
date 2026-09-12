#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The keybindings menu must show Mac physical key names: on Apple Silicon
# MacBook keyboards XF86MonBrightnessUp/Down ARE F2/F1, so raw symbols leak
# meaningless rows like "SHIFT + XF86MonBrightnessUp" (issue #194).
# Regression guard for the cache too: a pre-seeded stale cache file from the
# v13 era must not win over current rendering (cache key bumped to v14).

mock_bin=$(mktemp -d)
cache_dir=$(mktemp -d)
cleanup() {
  rm -rf "$mock_bin" "$cache_dir"
}
trap cleanup EXIT

cat >"$mock_bin/hyprctl" <<'SH'
#!/bin/bash
if [[ $1 == "devices" ]]; then
  echo "Keyboards:"
  echo "	active keymap: Apple Keyboard (apple_vndr)"
  exit 0
fi
cat <<'BINDS'
bindl
	modmask: 1
	key: XF86MonBrightnessUp
	keycode: 0
	description: Keyboard brightness up
	dispatcher: exec
	arg: omarchy-brightness-keyboard up

bindl
	modmask: 1
	key: XF86MonBrightnessDown
	keycode: 0
	description: Keyboard brightness down
	dispatcher: exec
	arg: omarchy-brightness-keyboard down

bindi
	modmask: 8
	key: XF86MonBrightnessUp
	keycode: 0
	description: Brightness up precise
	dispatcher: exec
	arg: omarchy-brightness-display +1%

bindm
	modmask: 64
	key: Q
	keycode: 0
	description: Close window
	dispatcher: killactive
	arg:
BINDS
SH
chmod +x "$mock_bin/hyprctl"

# Minimal valid keymap so keycode resolution has something to chew on.
cat >"$mock_bin/xkbcli" <<'SH'
#!/bin/bash
cat <<'KEYMAP'
xkb_keycodes {
    <AD01> = 24;
};
xkb_symbols {
    key <AD01> { [ q ] };
};
KEYMAP
SH
chmod +x "$mock_bin/xkbcli"

cat >"$mock_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$mock_bin/omarchy-cmd-present"

# Pre-seed the exact cache file that v13 production would read for these
# mocked inputs. Cached records use the rendered row as field 1, followed by
# the dispatcher and argument fields.
mkdir -p "$cache_dir/omarchy"
v13_key=$({
  printf 'v13\n'
  "$mock_bin/hyprctl" devices 2>/dev/null | grep -F 'active keymap:'
  "$mock_bin/hyprctl" binds 2>/dev/null
} | sha256sum | awk '{ print $1 }')
cat >"$cache_dir/omarchy/keybindings-$v13_key.records" <<'EOF'
SHIFT + XF86MonBrightnessUp → Keyboard brightness up	exec	omarchy-brightness-keyboard up
SHIFT + XF86MonBrightnessDown → Keyboard brightness down	exec	omarchy-brightness-keyboard down
ALT + XF86MonBrightnessUp → Brightness up precise	exec	omarchy-brightness-display +1%
SUPER + Q → Close window	killactive
EOF

output=$(PATH="$mock_bin:$PATH" XDG_CACHE_HOME="$cache_dir" "$ROOT/bin/omarchy-menu-keybindings" --print)

tr -s ' ' <<<"$output" | grep -qF '⇧ + F2 → Keyboard brightness up' || \
  fail "SHIFT + XF86MonBrightnessUp renders as ⇧ + F2 with its description" "$output"

tr -s ' ' <<<"$output" | grep -qF '⇧ + F1 → Keyboard brightness down' || \
  fail "SHIFT + XF86MonBrightnessDown renders as ⇧ + F1 with its description" "$output"

tr -s ' ' <<<"$output" | grep -qF '⌥ + F2 → Brightness up precise' || \
  fail "modifier combos keep the F-key name (⌥ + F2)" "$output"

grep -qF 'XF86MonBrightness' <<<"$output" && \
  fail "raw XF86MonBrightness symbols no longer leak into the menu" "$output"

tr -s ' ' <<<"$output" | grep -qF '⌘ + Q → Close window' || \
  fail "unrelated bindings use the Apple Command symbol (⌘ + Q)" "$output"

pass "keybindings menu shows Mac physical key names (F1/F2), stale caches ignored"
