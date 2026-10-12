#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The keybindings menu must show Mac physical key names: on Apple Silicon
# MacBook keyboards the whole top row sends media keysyms (hid-apple's 2021
# Magic Keyboard table: F1/F2 brightness, F3 Mission Control, F4 Spotlight,
# F5 dictation, F6 Do Not Disturb, F7-F9 media, F10-F12 volume), so raw
# symbols leak meaningless rows like "SHIFT + XF86MonBrightnessUp" or
# "SUPER + XF86AudioMute" (issue #194).
# Regression guard for the cache too: a pre-seeded stale cache file from the
# v13 era must not win over current rendering (cache key bumped since).

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

bind
	modmask: 64
	key: XF86AudioMute
	keycode: 0
	description: Screenshot Window (Apple top row)
	dispatcher: exec
	arg: omarchy-capture-screenshot windows

bindl
	modmask: 1
	key: XF86AudioPlay
	keycode: 0
	description: Switch media source
	dispatcher: exec
	arg: omarchy-audio-source-switch

bindl
	modmask: 0
	key: XF86AudioMicMute
	keycode: 0
	description: Mute microphone
	dispatcher: exec
	arg: omarchy-audio-input-mute

bindl
	modmask: 0
	key: XF86LaunchA
	keycode: 0
	description: Mission Control
	dispatcher: exec
	arg: omarchy-menu toggle apps

bindl
	modmask: 0
	key: XF86Sleep
	keycode: 0
	description: Do Not Disturb
	dispatcher: exec
	arg: omarchy-toggle-dnd

bindl
	modmask: 0
	key: XF86Calculator
	keycode: 0
	description: Calculator
	dispatcher: exec
	arg: omacalc

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

tr -s ' ' <<<"$output" | grep -qF 'SHIFT + F2 → Keyboard brightness up' || \
  fail "SHIFT + XF86MonBrightnessUp renders as SHIFT + F2 with its description" "$output"

tr -s ' ' <<<"$output" | grep -qF 'SHIFT + F1 → Keyboard brightness down' || \
  fail "SHIFT + XF86MonBrightnessDown renders as SHIFT + F1 with its description" "$output"

tr -s ' ' <<<"$output" | grep -qF 'ALT + F2 → Brightness up precise' || \
  fail "modifier combos keep the F-key name (ALT + F2)" "$output"

grep -qF 'XF86MonBrightness' <<<"$output" && \
  fail "raw XF86MonBrightness symbols no longer leak into the menu" "$output"

tr -s ' ' <<<"$output" | grep -qF 'SUPER + Q → Close window' || \
  fail "unrelated bindings render unchanged (SUPER + Q)" "$output"

tr -s ' ' <<<"$output" | grep -qF 'SUPER + F10 → Screenshot Window (Apple top row)' || \
  fail "SUPER + XF86AudioMute renders as SUPER + F10" "$output"

tr -s ' ' <<<"$output" | grep -qF 'SHIFT + F8 → Switch media source' || \
  fail "SHIFT + XF86AudioPlay renders as SHIFT + F8" "$output"

tr -s ' ' <<<"$output" | grep -qF 'F5 → Mute microphone' || \
  fail "XF86AudioMicMute (dictation key) renders as F5" "$output"

tr -s ' ' <<<"$output" | grep -qF 'F3 → Mission Control' || \
  fail "XF86LaunchA (Mission Control key) renders as F3" "$output"

tr -s ' ' <<<"$output" | grep -qF 'F6 → Do Not Disturb' || \
  fail "XF86Sleep (Do Not Disturb key) renders as F6" "$output"

tr -s ' ' <<<"$output" | grep -qF 'XF86Calculator → Calculator' || \
  fail "keysyms that are not on the Apple top row keep their name (XF86Calculator)" "$output"

grep -qE 'XF86(MonBrightness|Audio(Mute|Play|MicMute)|LaunchA|Sleep)' <<<"$output" && \
  fail "raw Apple top-row symbols no longer leak into the menu" "$output"

pass "keybindings menu shows Mac physical key names for the whole top row, stale caches ignored"
