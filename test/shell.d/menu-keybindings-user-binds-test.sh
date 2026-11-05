#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command lua

# The keybindings menu recovers Lua binds (dispatcher __lua in `hyprctl binds`)
# by running the user's hyprland.lua under a stub `hl`. The stock tree that
# config loads first calls hl.get_active_monitor() and compares a field of the
# answer with a number (qconsole.lua); a stub that answers with the catch-all
# proxy table aborts the whole load there, before hyprland.lua reaches
# require("hypr.bindings"), so no user bind ever resolves (issue #685). Load
# the real stock tree, exactly as production does, and check a user bind
# defined after it comes back with its command.

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

home="$tmpdir/home"
stub_bin="$tmpdir/bin"
mkdir -p "$home/.config" "$stub_bin"
cp -r "$ROOT/config/hypr" "$home/.config/hypr"
cat >>"$home/.config/hypr/bindings.lua" <<'LUA'
o.bind("SUPER + Y", "User command", "user-command --flag")
LUA

cat >"$stub_bin/hyprctl" <<'SH'
#!/bin/bash
case "$1" in
  binds)
    printf 'bind\n\tmodmask: 64\n\tsubmap: \n\tkey: Y\n\tkeycode: 0\n\tcatchall: false\n\tdescription: User command\n\tdispatcher: __lua\n\targ: \n\n'
    printf 'bind\n\tmodmask: 64\n\tsubmap: \n\tkey: K\n\tkeycode: 0\n\tcatchall: false\n\tdescription: Keybindings\n\tdispatcher: __lua\n\targ: \n'
    ;;
  devices) echo "active keymap: English (US)" ;;
esac
SH
chmod +x "$stub_bin/hyprctl"

debug=$(env -i PATH="$stub_bin:$ROOT/bin:$PATH" HOME="$home" XDG_CACHE_HOME="$tmpdir/cache" \
  OMARCHY_PATH="$ROOT" DEBUG=1 bash "$ROOT/bin/omarchy-menu-keybindings" --print 2>&1 >/dev/null || true)

if grep -q 'lua bind scan failed' <<<"$debug"; then
  fail "the stock tree loads under the bind scanner's stub hl" "$debug"
fi
pass "the stock tree loads under the bind scanner's stub hl"

records=$(cat "$tmpdir"/cache/omarchy/keybindings-*.records)

if tr -s ' ' <<<"$records" | grep -qF $'SUPER + Y → User command\texec\tuser-command --flag'; then
  pass "a user bind defined after the stock tree resolves to its command"
else
  fail "a user bind defined after the stock tree resolves to its command" "$records"
fi

if tr -s ' ' <<<"$records" | grep -qF $'SUPER + K → Keybindings\texec\tomarchy-menu-keybindings'; then
  pass "a stock bind still resolves"
else
  fail "a stock bind still resolves" "$records"
fi
