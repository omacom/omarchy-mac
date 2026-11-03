#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

migration=$(grep -l 'install/user/hardware/apple/bashrc.sh' "$ROOT"/migrations/*.sh)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# omarchy-hw-apple reads uname, so stand in for it to pick the platform.
stub_bin="$test_dir/bin"
mkdir -p "$stub_bin"

stock="$test_dir/stock.bashrc"
cat >"$stock" <<'STOCK'
#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
STOCK

run_migration() {
  local home="$1" apple="$2"

  printf '#!/bin/bash\nexit %s\n' "$apple" >"$stub_bin/omarchy-hw-apple"
  chmod +x "$stub_bin/omarchy-hw-apple"
  HOME="$home" OMARCHY_PATH="$ROOT" OMARCHY_STOCK_BASHRC="$stock" PATH="$stub_bin:$PATH" \
    bash -euo pipefail "$migration" >/dev/null
}

new_home() {
  local home="$test_dir/$1"
  mkdir -p "$home"
  printf '%s' "$home"
}

# A stock bashrc on Apple Silicon becomes Omarchy's, with a backup.
home=$(new_home stock)
cp "$stock" "$home/.bashrc"
run_migration "$home" 0
cmp -s "$ROOT/default/bashrc" "$home/.bashrc" || fail "stock bashrc is replaced by Omarchy's"
compgen -G "$home/.bashrc.backup-*" >/dev/null || fail "stock bashrc is backed up"
pass "stock bashrc is replaced by Omarchy's"

# The installed bashrc really defines cx once sourced.
defined=$(HOME="$home" OMARCHY_PATH="$ROOT" bash -ic 'alias cx' 2>/dev/null || true)
[[ $defined == *"claude"* ]] || fail "installed bashrc defines cx" "$defined"
pass "installed bashrc defines cx"

# User additions on top of the stock file are carried over; stock lines are not.
home=$(new_home custom)
{ cat "$stock"; echo 'alias hx="helix"'; } >"$home/.bashrc"
run_migration "$home" 0
grep -qxF 'alias hx="helix"' "$home/.bashrc" || fail "user additions are kept"
grep -qxF "alias ls='ls --color=auto'" "$home/.bashrc" && fail "stock lines are dropped"
grep -qF 'default/bash/rc' "$home/.bashrc" || fail "custom bashrc sources Omarchy's rc"
pass "user additions are kept and stock lines dropped"

# A missing bashrc is installed.
home=$(new_home missing)
run_migration "$home" 0
cmp -s "$ROOT/default/bashrc" "$home/.bashrc" || fail "missing bashrc is installed"
pass "missing bashrc is installed"

# A bashrc that already sources Omarchy's rc is left alone.
home=$(new_home omarchy)
{ cat "$ROOT/default/bashrc"; echo 'alias p=python'; } >"$home/.bashrc"
before=$(<"$home/.bashrc")
run_migration "$home" 0
[[ $(<"$home/.bashrc") == "$before" ]] || fail "Omarchy bashrc is left alone"
compgen -G "$home/.bashrc.backup-*" >/dev/null && fail "Omarchy bashrc is not backed up"
pass "Omarchy bashrc is left alone"

# Other platforms are untouched.
home=$(new_home x86)
cp "$stock" "$home/.bashrc"
run_migration "$home" 1
cmp -s "$stock" "$home/.bashrc" || fail "non-Apple bashrc is left alone"
pass "non-Apple bashrc is left alone"
