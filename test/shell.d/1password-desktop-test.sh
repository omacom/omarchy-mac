#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1790792558.sh"
override="$ROOT/default/applications/1password.desktop"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
test_home="$test_tmp/home"
desktop="$test_home/.local/share/applications/1password.desktop"
mkdir -p "$mock_bin" "$test_home"

cat >"$mock_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
[[ $1 == "1password" && ${OMARCHY_TEST_INSTALLED:-1} == 1 ]]
SH

# The remover's system cleanup must never reach the real machine.
cat >"$mock_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_SUDO_LOG"
SH

printf '#!/bin/bash\n' >"$mock_bin/omarchy-pkg-drop"
printf '#!/bin/bash\n' >"$mock_bin/update-desktop-database"
chmod +x "$mock_bin"/*

run() {
  OMARCHY_PATH="$ROOT" HOME="$test_home" PATH="$mock_bin:$ROOT/bin:$PATH" \
    OMARCHY_TEST_SUDO_LOG="$test_tmp/sudo-log" "$@" >/dev/null 2>&1
}

run_migration() {
  run bash -euo pipefail "$migration"
}

vendor_entry() {
  printf '[Desktop Entry]\nName=1Password\nExec=%s\nType=Application\n' "$1"
}

grep -qx 'Exec=omarchy-launch-1password %U' "$override" ||
  fail "the desktop entry passes URLs to the launcher"
grep -qx 'MimeType=x-scheme-handler/onepassword;' "$override" ||
  fail "the desktop entry handles onepassword:// URLs"
pass "the desktop entry routes app launchers and onepassword:// URLs through the launcher"

OMARCHY_TEST_INSTALLED=0 run_migration || fail "the migration succeeds without 1Password"
[[ ! -e $desktop ]] || fail "the migration installs no entry without 1Password"
pass "the migration leaves machines without 1Password alone"

run_migration || fail "the migration installs the entry"
cmp -s "$override" "$desktop" || fail "the migration installs the Omarchy entry"
run_migration || fail "rerunning the migration succeeds"
cmp -s "$override" "$desktop" || fail "rerunning the migration keeps the Omarchy entry"
pass "the migration installs the entry and is idempotent"

for exec in "/opt/1Password/1password %U" "/usr/local/bin/1password %U" \
  "/opt/1Password/1password --force-device-scale-factor=1 %U"; do
  vendor_entry "$exec" >"$desktop"
  run_migration || fail "the migration replaces a direct 1Password entry: $exec"
  cmp -s "$override" "$desktop" || fail "the migration replaces a direct 1Password entry: $exec"
done
pass "the migration replaces entries that start 1Password directly"

# The Apple wrapper repair runs again on every 1Password install and repair.
run_migration
touch -d '2000-01-01' "$desktop"
run "$ROOT/bin/omarchy-cmd-desktop-exec-repair" "$desktop" "$test_tmp/missing-vendor" \
  /usr/local/bin/1password /opt/1Password/1password 1password
cmp -s "$override" "$desktop" && [[ $(stat -c %Y "$desktop") == "$(date -d '2000-01-01' +%s)" ]] ||
  fail "the wrapper repair leaves the launcher entry untouched"
pass "the wrapper repair leaves the launcher entry untouched"

vendor_entry "env FOO=1 /opt/1Password/1password %U" >"$desktop"
custom=$(<"$desktop")
run_migration || fail "the migration succeeds with a custom entry"
[[ $(<"$desktop") == "$custom" ]] || fail "the migration preserves a custom command"
rm "$desktop"
vendor_entry "/opt/1Password/1password %U" >"$test_tmp/linked.desktop"
ln -s "$test_tmp/linked.desktop" "$desktop"
run_migration || fail "the migration succeeds with a linked entry"
[[ -L $desktop ]] && cmp -s <(vendor_entry "/opt/1Password/1password %U") "$test_tmp/linked.desktop" ||
  fail "the migration preserves a linked entry and its target"
rm "$desktop"
pass "the migration preserves custom commands and links"

run_migration
run "$ROOT/bin/omarchy-remove-service-1password"
[[ ! -e $desktop ]] || fail "removing 1Password removes the launcher entry"
vendor_entry "env FOO=1 /opt/1Password/1password %U" >"$desktop"
run "$ROOT/bin/omarchy-remove-service-1password"
[[ -f $desktop ]] || fail "removing 1Password keeps a custom entry"
pass "removing 1Password removes only the launcher entry"
