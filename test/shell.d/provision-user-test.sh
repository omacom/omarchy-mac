#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin" "$test_tmp/home" "$test_tmp/home/.hermes/profiles/james"

for command in xdg-user-dirs-update xdg-settings xdg-mime; do
  printf '#!/bin/bash\nexit 0\n' >"$mock_bin/$command"
done
chmod +x "$mock_bin"/*

# Provisioning prepends $OMARCHY_PATH/bin, which shadows a mock for anything
# Omarchy ships, so the install suite is stubbed out at its path instead. The
# real one rethemes the session it runs in: hyprctl reload against the live
# compositor, gsettings against the live desktop, and a global Node install.
mkdir -p "$test_tmp/install/user"
: >"$test_tmp/install/user/all.sh"

HOME="$test_tmp/home" PATH="$mock_bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
  OMARCHY_INSTALL="$test_tmp/install" bash "$ROOT/bin/omarchy-provision-user" >/dev/null ||
  fail "omarchy-provision-user finishes"

for skill in omarchy diagnose-crash; do
  link="$test_tmp/home/.gemini/config/skills/$skill"
  [[ -L $link && $(readlink "$link") == "$ROOT/default/agents/skills/$skill" ]] ||
    fail "omarchy-provision-user provisions the $skill skill for Antigravity"

  link="$test_tmp/home/.hermes/skills/$skill"
  [[ -L $link && $(readlink "$link") == "$ROOT/default/agents/skills/$skill" ]] ||
    fail "omarchy-provision-user provisions the $skill skill for Hermes"

  link="$test_tmp/home/.hermes/profiles/james/skills/$skill"
  [[ -L $link && $(readlink "$link") == "$ROOT/default/agents/skills/$skill" ]] ||
    fail "omarchy-provision-user provisions the $skill skill for a Hermes profile"
done

pass "omarchy-provision-user provisions Antigravity and Hermes skills"

# A first install marks every shipped migration done, so omarchy update never
# replays them on it: the one that adds the unsigned [omarchy-aarch64] on
# Apple Silicon installs older than the signed repository included.
mkdir -p "$test_tmp/first-home"
HOME="$test_tmp/first-home" PATH="$mock_bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
  OMARCHY_INSTALL="$test_tmp/install" bash "$ROOT/bin/omarchy-provision-user" --first-install >/dev/null ||
  fail "omarchy-provision-user --first-install finishes"
[[ -f $test_tmp/first-home/.local/state/omarchy/migrations/1788200000.sh ]] ||
  fail "a first install marks the [omarchy-aarch64] migration done"
for migration in "$ROOT"/migrations/*.sh; do
  [[ -f $test_tmp/first-home/.local/state/omarchy/migrations/$(basename "$migration") ]] ||
    fail "a first install marks every shipped migration done: $(basename "$migration")"
done
HOME="$test_tmp/first-home" OMARCHY_PATH="$ROOT" OMARCHY_MIGRATION_STATE="$test_tmp/first-home/.local/state/omarchy/migrations" \
  "$ROOT/bin/omarchy-migrate" --pending >/dev/null && fail "a first install leaves no migration pending"
pass "a first install marks every shipped migration done, the [omarchy-aarch64] one included"
