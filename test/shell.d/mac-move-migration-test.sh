#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Migration 1791080196 marks an Apple Silicon Mac for the move onto Omarchy's
# official packages, once and machine-wide; omarchy update then runs
# omarchy-mac-migrate before any fork step and stops once it moved the Mac.
migration=$ROOT/migrations/1791080196.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/bash\n[[ $(cat "$FIXTURE/platform") == apple ]]\n' >"$tmp/bin/omarchy-hw-apple"
cat >"$tmp/bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >>"$FIXTURE/ran"
exec "$@"
SH
chmod 755 "$tmp/bin"/*
marker=$tmp/state/1791080196

run_migration() {
  rm -f "$tmp/ran"
  FIXTURE=$tmp PATH="$tmp/bin:$PATH" OMARCHY_PATH=$ROOT OMARCHY_MAC_MOVE_MARKER=$marker bash -euo pipefail "$migration"
}

[[ $(stat -c %a "$migration") == 644 ]] || fail "the migration is mode 644"
head -n 1 "$migration" | grep -q '^echo ' || fail "the migration starts with an echo"

echo generic >"$tmp/platform"
run_migration >/dev/null || fail "another platform: the migration completes"
[[ ! -e $tmp/ran && ! -e $marker ]] || fail "another platform: nothing runs"
pass "anything but an Apple Silicon Mac completes the migration and marks nothing"

echo apple >"$tmp/platform"
run_migration >/dev/null || fail "a Mac: the migration completes"
[[ -e $marker ]] && grep -q "^sudo install -Dm644 /dev/null $marker$" "$tmp/ran" || fail "a Mac is marked as root" "$(cat "$tmp/ran" 2>/dev/null)"
run_migration >/dev/null && [[ ! -e $tmp/ran ]] || fail "another account: nothing runs once the Mac is marked"
pass "a Mac is marked for the move once, machine-wide"

# The move comes first in omarchy update, before any fork update, and the
# update stops once it has run.
update=$ROOT/bin/omarchy-update
move=$(grep -n 'sudo "$OMARCHY_PATH/bin/omarchy-mac-migrate" run || move_status' "$update" | cut -d: -f1)
dev=$(grep -n '^    omarchy-update-dev$' "$update" | cut -d: -f1)
system=$(grep -n '^  omarchy-update-system-pkgs$' "$update" | cut -d: -f1)
[[ -n $move && -n $dev && -n $system ]] && (( move < dev && move < system )) || fail "omarchy update moves a marked Mac before any fork update" "move $move dev $dev system $system"
grep -q '/var/lib/omarchy/migrations/1791080196' "$update" || fail "omarchy update moves only a marked Mac"
awk -v from="$move" 'NR > from && /move_status == 0/ { found = 1 } found && /exit 0/ { ok = 1; exit } END { exit !ok }' "$update" ||
  fail "a moved Mac's update stops there"
awk -v from="$move" 'NR > from && /move_status == 75/ { found = 1 } found && /updating this Mac as before/ { ok = 1; exit } END { exit !ok }' "$update" ||
  fail "a deferred move lets the fork update go on"
pass "omarchy update moves a marked Mac before any fork update, stops once it moved, and goes on when the move defers"

# The update hook's three outcomes, run for real against a stand-in tool.
for outcome in 0 75 1 nothing; do
  work=$tmp/update-$outcome
  mkdir -p "$work/bin" "$work/omarchy/bin"
  code=$outcome
  [[ $outcome != nothing ]] || code=0
  printf '#!/bin/bash\necho "migrate $*" >>"%s/ran"\nexit %s\n' "$work" "$code" >"$work/omarchy/bin/omarchy-mac-migrate"
  for command in omarchy-update-lock omarchy-update-requires-free-space omarchy-update-confirm omarchy-update-pkg-prune omarchy-snapshot \
    omarchy-update-stay-awake omarchy-update-dev omarchy-update-keyring omarchy-update-system-pkgs omarchy-migrate omarchy-hook \
    omarchy-update-aur-pkgs omarchy-update-mise omarchy-update-orphan-pkgs omarchy-update-analyze-logs omarchy-update-status omarchy-update-restart; do
    printf '#!/bin/bash\n[[ $1 == held ]] && exit 0\necho "%s $*" >>"%s/ran"\n' "$command" "$work" >"$work/bin/$command"
  done
  printf '#!/bin/bash\nexec "$@"\n' >"$work/bin/sudo"
  chmod 755 "$work/bin"/* "$work/omarchy/bin"/*
  : >"$work/marker"
  status=0
  mkdir -p "$work/state"
  if [[ $outcome == 0 ]]; then
    : >"$work/state/reboot-pending"
  fi
  OMARCHY_UPDATE_LOGGED=1 OMARCHY_MAC_MOVE_MARKER=$work/marker OMARCHY_MAC_MOVE_STATE=$work/state OMARCHY_PATH=$work/omarchy PATH="$work/bin:$PATH" \
    bash "$update" -y >"$work/out" 2>&1 || status=$?
  case $outcome in
    nothing) (( status == 0 )) && grep -q '^omarchy-update-system-pkgs' "$work/ran" ||
      fail "a run that moved nothing lets the fork update go on" "$(cat "$work/ran" "$work/out")" ;;
    0) (( status == 0 )) && ! grep -q '^omarchy-update-dev\|^omarchy-update-system-pkgs' "$work/ran" && grep -q "now runs Omarchy's official packages" "$work/out" ||
      fail "a moved Mac's update stops before any fork step" "$(cat "$work/ran" "$work/out")" ;;
    75) (( status == 0 )) && grep -q '^omarchy-update-system-pkgs' "$work/ran" && grep -q '^omarchy-migrate' "$work/ran" ||
      fail "a deferred move updates the Mac as before" "$(cat "$work/ran" "$work/out")" ;;
    1) (( status != 0 )) && ! grep -q '^omarchy-update-system-pkgs' "$work/ran" ||
      fail "a failed move stops the update" "$(cat "$work/ran" "$work/out")" ;;
  esac
done
pass "omarchy update stops after a move, goes on after a deferral or a run that moved nothing, and stops on a failure"
