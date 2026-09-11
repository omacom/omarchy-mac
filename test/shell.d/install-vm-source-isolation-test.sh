#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# Exercise source staging without root or an actual guest. The guest identity
# deliberately differs from the host, as it does on GitHub-hosted runners.
harness="$ROOT/test/vm/run-selective-edge"
eval "$(sed -n '/^stage_source() {/,/^}/p' "$ROOT/test/vm/run-selective-edge")"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
ROOT="$test_tmp/checkout"
SOURCE="$test_tmp/source"
GUEST_USER=ci
mkdir -p "$ROOT/.git" "$SOURCE"
printf 'original\n' >"$ROOT/install.sh"
printf 'ref: refs/heads/test\n' >"$ROOT/.git/HEAD"
nspawn() {
  [[ $1 == "id" && $3 == "$GUEST_USER" ]] || fail "unexpected guest operation"
  if [[ $2 == "-u" ]]; then echo 12345; else echo 23456; fi
}
as_root() {
  if [[ $1 == "chown" ]]; then
    printf '%s\n' "$*" >"$test_tmp/chown"
  else
    "$@"
  fi
}
stage_source
[[ $(cat "$test_tmp/chown") == "chown -R 12345:23456 $SOURCE" ]] ||
  fail "source staging must use guest ownership only on its private copy"
cmp "$ROOT/.git/HEAD" "$SOURCE/.git/HEAD" || fail "staging must retain git metadata for package builds"
printf 'guest writes\n' >"$SOURCE/install.sh"
[[ $(cat "$ROOT/install.sh") == "original" ]] || fail "guest writes must not affect the checkout"
pass "guest source staging preserves git metadata and isolates mismatched UID ownership"

# Linked worktrees must remain usable after their host gitdir is unavailable.
git init -q "$test_tmp/repository"
printf 'tracked\n' > "$test_tmp/repository/payload"
git -C "$test_tmp/repository" add payload
git -C "$test_tmp/repository" -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false commit -qm fixture
git -C "$test_tmp/repository" worktree add -q --detach "$test_tmp/worktree"
ROOT="$test_tmp/worktree"
SOURCE="$test_tmp/worktree-source"
OMARCHY_PKGS_PATH="$test_tmp/recipes"
mkdir -p "$SOURCE" "$OMARCHY_PKGS_PATH/pkgbuilds"
printf 'pinned recipe\n' > "$OMARCHY_PKGS_PATH/pkgbuilds/fixture"
stage_source
[[ -d $SOURCE/.git ]] || fail "worktree staging must replace the host gitdir pointer"
[[ $(git -C "$SOURCE" ls-files payload) == "payload" ]] || fail "staged worktree must retain its tracked-file index"
[[ $(git -C "$SOURCE" rev-parse HEAD) == "$(git -C "$ROOT" rev-parse HEAD)" ]] || fail "staged worktree must retain source revision"
cmp "$OMARCHY_PKGS_PATH/pkgbuilds/fixture" "$SOURCE/omarchy-pkgs/pkgbuilds/fixture" || fail "supplied recipes must be staged for the guest"
printf 'guest change\n' > "$SOURCE/omarchy-pkgs/pkgbuilds/fixture"
[[ $(cat "$OMARCHY_PKGS_PATH/pkgbuilds/fixture") == "pinned recipe" ]] || fail "guest recipe writes must not affect the host"
pass "linked worktree metadata and supplied recipes remain independent in the guest"
unset OMARCHY_PKGS_PATH

# Exercise the real wrapper so a host's older default seccomp list cannot hide
# the kernel's Landlock support from pacman's download sandbox.
eval "$(sed -n '/^nspawn() {/,/^}/p' "$harness")"
WORK="$test_tmp/work"
as_root() { printf '%s\n' "$@" >"$test_tmp/nspawn-args"; }
nspawn /bin/true
mapfile -t args <"$test_tmp/nspawn-args"
[[ ${args[0]} == "systemd-nspawn" ]] || fail "wrapper must invoke nspawn"
filters=0
for arg in "${args[@]}"; do
  if [[ $arg == --system-call-filter=* ]]; then
    [[ $arg == "--system-call-filter=landlock_create_ruleset landlock_add_rule landlock_restrict_self" ]] ||
      fail "wrapper must add only the Landlock sandbox APIs to the default filter"
    filters=$((filters + 1))
  fi
done
(( filters == 1 )) || fail "wrapper must preserve Landlock availability for pacman"
pass "nspawn permits pacman's Landlock APIs without disabling its default syscall filter"
