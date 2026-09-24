#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

tmpdir=$(mktemp -d) && [[ -n $tmpdir && -d $tmpdir ]] ||
  fail "the test gets a temporary directory for keybinding command stubs"
trap 'rm -rf "$tmpdir"' EXIT

stub_bin="$tmpdir/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/tmux" <<'TMUX'
#!/bin/bash
cat <<'OUTPUT'
prefix C-a
prefix2 M-b
prefix C-S-x Example binding
root M-y Root binding
copy-mode-vi C-z Copy binding
copy-mode-vi BTab Reverse selection
OUTPUT
TMUX
chmod +x "$stub_bin/tmux"

touch "$tmpdir/tmux.conf"
tmux_output=$(PATH="$stub_bin:$PATH" OMARCHY_PATH="$ROOT" \
  "$ROOT/bin/omarchy-menu-tmux-keybindings" --print --config "$tmpdir/tmux.conf")

grep -q '^PREFIX  *→ ⌃ + A / ⌥ + B$' <<<"$tmux_output" ||
  fail "Tmux prefix modifiers use Apple symbols" "$tmux_output"
grep -qF 'PREFIX + ⌃ + ⇧ + X' <<<"$tmux_output" ||
  fail "Tmux binding modifiers use Apple symbols" "$tmux_output"
grep -qF '⌥ + Y' <<<"$tmux_output" ||
  fail "Tmux root modifiers use Apple symbols" "$tmux_output"
grep -qF 'COPY MODE + ⇧ + TAB' <<<"$tmux_output" ||
  fail "Tmux BTab uses the Apple Shift symbol" "$tmux_output"
pass "Tmux keybindings use Apple modifier symbols"

cat >"$stub_bin/herdr" <<'HERDR'
#!/bin/bash
cat <<'OUTPUT'
#[keys]
# prefix = "control+a"
# navigate_left = "super+alt+shift+h"
# close = "ctrl+w"
# toggle = ["super+control+shift+alt+a", "super+control+shift+alt+b", "super+control+shift+alt+c", "super+control+shift+alt+d"]
OUTPUT
HERDR
chmod +x "$stub_bin/herdr"

herdr_output=$(PATH="$stub_bin:$PATH" \
  "$ROOT/bin/omarchy-menu-herdr-keybindings" --print --config /dev/null)

grep -q '^PREFIX  *→ ⌃ + A$' <<<"$herdr_output" ||
  fail "Herdr prefix modifiers use Apple symbols" "$herdr_output"
grep -qF 'NAVIGATE + ⌘ + ⌥ + ⇧ + H' <<<"$herdr_output" ||
  fail "Herdr navigation modifiers use Apple symbols" "$herdr_output"
grep -qF '⌃ + W' <<<"$herdr_output" ||
  fail "Herdr CTRL aliases use the Control symbol" "$herdr_output"
grep -qF '⌘ + ⌃ + ⇧ + ⌥ + A / ⌘ + ⌃ + ⇧ + ⌥ + B / ⌘ + ⌃ + ⇧ + ⌥ + C / ⌘ + ⌃ + ⇧ + ⌥ + D → Toggle' <<<"$herdr_output" ||
  fail "Herdr chords longer than the display column are not padded backwards" "$herdr_output"
pass "Herdr keybindings use Apple modifier symbols"
