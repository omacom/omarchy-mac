#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
home="$test_tmp/home"
mkdir -p "$stub_bin" "$home"

cat >"$stub_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$stub_bin/git" <<'SH'
#!/bin/bash
# Pretend to clone LazyVim/starter without touching the network.
dest=${*: -1}
mkdir -p "$dest/lua"
exit 0
SH

chmod +x "$stub_bin"/*

HOME="$home" PATH="$stub_bin:$PATH" "$ROOT/bin/omarchy-lazyvim-setup" >/dev/null

link="$home/.config/nvim/lua/plugins/omarchy-theme.lua"
[[ -L $link ]] || fail "lazyvim setup links the omarchy theme plugin"
target=$(readlink "$link")
[[ $target == "$home/.local/state/omarchy/current/theme/neovim.lua" ]] ||
  fail "lazyvim setup points at the current theme-state path" "$target"
pass "lazyvim setup links neovim.lua from the Quattro theme-state path"
