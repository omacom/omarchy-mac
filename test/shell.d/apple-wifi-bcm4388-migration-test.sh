#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
installed="$test_tmp/installed"
mkdir -p "$stub_bin" "$test_tmp/omarchy/migrations"

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
[[ ${APPLE:-1} == 1 ]]
SH

cat >"$stub_bin/lspci" <<'SH'
#!/bin/bash
echo "01:00.0 Network controller [0280]: Broadcom Inc. Wireless [14e4:${WIFI_ID:-4434}]"
for _ in {1..4096}; do
  echo '02:00.0 Host bridge [0600]: Filler Device [ffff:0000]'
done
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >>"$CALLS"
"$@"
SH

cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
echo "pacman $*" >>"$CALLS"
if [[ $1 == "-Q" ]]; then
  [[ -e $INSTALLED ]]
else
  touch "$INSTALLED"
fi
SH

cat >"$stub_bin/omarchy-mac-setup-system" <<'SH'
#!/bin/bash
echo "omarchy-mac-setup-system" >>"$CALLS"
exit "${SETUP_STATUS:-0}"
SH

cat >"$stub_bin/omarchy-mac-setup-user" <<'SH'
#!/bin/bash
echo "omarchy-mac-setup-user" >>"$CALLS"
SH

# The installed add-on's chipset gate: an add-on older than this change answers no.
cat >"$stub_bin/wifi-supported" <<'SH'
#!/bin/bash
[[ ${ADDON_COVERS_4434:-1} == 1 ]]
SH

chmod +x "$stub_bin"/*
ln -s "$ROOT/bin/omarchy-setup-mac" "$stub_bin/omarchy-setup-mac"

source_migration="$ROOT/migrations/1790327076.sh"
[[ $(stat -c %a "$source_migration") == 644 ]] || fail "the migration is sourced, not executed" "$(stat -c %a "$source_migration")"
[[ $(head -n 1 "$source_migration") == echo* ]] || fail "the migration starts with an echo"
migration="$test_tmp/omarchy/migrations/1790327076.sh"
sed "s|/usr/lib/omarchy-mac/wifi-supported|$stub_bin/wifi-supported|" "$source_migration" >"$migration"
grep -Fq "$stub_bin/wifi-supported" "$migration" || fail "the test reaches the add-on's chipset gate"

export CALLS="$calls" INSTALLED="$installed" PATH="$stub_bin:$PATH"

run_migration() {
  : >"$calls"
  bash -euo pipefail "$migration"
}

touch "$installed"
APPLE=0 run_migration >/dev/null
WIFI_ID=4433 run_migration >/dev/null
WIFI_ID=4425 run_migration >/dev/null
[[ ! -s $calls ]] || fail "other Macs and other hardware never reach sudo" "$(cat "$calls")"
pass "only Apple Silicon Macs with BCM4388 run setup"

run_migration >/dev/null
grep -Fxq 'sudo omarchy-mac-setup-system' "$calls" || fail "a BCM4388 Mac runs system setup" "$(cat "$calls")"
! grep -Fq 'omarchy-mac-setup-user' "$calls" || fail "the migration leaves user setup alone" "$(cat "$calls")"
! grep -Fq 'pacman -S' "$calls" || fail "an installed add-on is not reinstalled" "$(cat "$calls")"
pass "a BCM4388 Mac with the add-on runs system setup only"

rm "$installed"
run_migration >/dev/null
grep -Fq 'pacman -S --needed --noconfirm omarchy-mac' "$calls" || fail "a missing add-on comes from the sync repository" "$(cat "$calls")"
grep -Fxq 'sudo omarchy-mac-setup-system' "$calls" || fail "setup follows the install" "$(cat "$calls")"
pass "a BCM4388 Mac without the add-on installs it before setup"

status=0
SETUP_STATUS=43 run_migration >/dev/null 2>&1 || status=$?
(( status == 43 )) || fail "a setup failure fails the migration" "$status"
pass "a setup failure fails the migration"

# Through the runner: an add-on that predates BCM4388 keeps the migration pending until it is updated.
export OMARCHY_PATH="$test_tmp/omarchy" OMARCHY_MIGRATION_STATE="$test_tmp/state"
marker="$OMARCHY_MIGRATION_STATE/1790327076.sh"
status=0
ADDON_COVERS_4434=0 "$ROOT/bin/omarchy-migrate" >"$test_tmp/out" 2>&1 || status=$?
(( status != 0 )) && [[ ! -e $marker ]] || fail "an old add-on leaves the migration pending" "$(cat "$test_tmp/out")"
grep -q 'does not cover BCM4388' "$test_tmp/out" || fail "the pending migration says why" "$(cat "$test_tmp/out")"
[[ $("$ROOT/bin/omarchy-migrate" --pending) == 1790327076.sh ]] || fail "the runner lists the migration as pending"
"$ROOT/bin/omarchy-migrate" >"$test_tmp/out" 2>&1 || fail "the updated add-on completes the migration" "$(cat "$test_tmp/out")"
[[ -e $marker ]] || fail "the completed migration is marked"
pass "an add-on that predates BCM4388 keeps the migration pending until it is updated"
