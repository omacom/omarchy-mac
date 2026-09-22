#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/bin/omarchy-mac-snapper-backend"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
real_mv=$(command -v mv)
fixture_volume() { mkdir -p "$1"; printf '%s\n' "$2" >"$1/.uuid"; }
backend_uuid() {
  [[ ${FAIL_UUID:-} != "$1" ]] || return 65
  case "$1" in /) echo "$TEST_RUNNING_UUID";; /.snapshots) [[ -n ${TEST_ATTACHED:-} ]] && echo "$TEST_ATTACHED";; *) [[ -f $1/.uuid ]] && cat "$1/.uuid";; esac
}
backend_info() {
  case "$2" in UUID) backend_uuid "$1";; 'Parent UUID') cat "$1/.parent";; 'Subvolume ID') echo 258;; esac
}
backend_is_volume() { [[ -f $1/.uuid && ! -L $1 ]]; }
mount() { [[ ${FAIL_MOUNT:-0} == 0 ]] || return 71; TEST_ATTACHED=$BACKEND_HISTORY_UUID; }
sync() { :; }
mv() {
  MOVE_NUMBER=$((MOVE_NUMBER + 1))
  [[ ${FAIL_MOVE:-0} != "$MOVE_NUMBER" ]] || return 72
  "$real_mv" "$@"
}
btrfs() {
  case "$1 $2" in
    'subvolume snapshot')
      cp -a "$3" "$4"
      echo "$NEW_UUID" >"$4/.uuid" ;;
    'subvolume delete')
      [[ $(backend_uuid "$3") == "$NEW_UUID" ]] || return 79
      [[ ! -f $3/.snapshots/.uuid ]] || return 78
      rm -r "$3" ;;
    *) return 99 ;;
  esac
}
ROOT_UUID=11111111-1111-1111-1111-111111111111
NEW_UUID=22222222-2222-2222-2222-222222222222
HISTORY_UUID=33333333-3333-3333-3333-333333333333
SNAPSHOT_UUID=44444444-4444-4444-4444-444444444444
new_fixture() {
  BACKEND_TOP="$test_tmp/$1"
  BACKEND_RECEIPT="$BACKEND_TOP/.omarchy-snapper-restore"
  BACKEND_DEVICE=/test-only
  TEST_RUNNING_UUID=$ROOT_UUID TEST_ATTACHED="" MOVE_NUMBER=0 FAIL_MOVE=0 FAIL_MOUNT=0 FAIL_UUID="" BACKEND_NO_HISTORY=0
  fixture_volume "$BACKEND_TOP/@" "$ROOT_UUID"
  fixture_volume "$BACKEND_TOP/@/.snapshots" "$HISTORY_UUID"
  fixture_volume "$BACKEND_TOP/@/.snapshots/1/snapshot" "$SNAPSHOT_UUID"
  mkdir -p "$BACKEND_TOP/@/.snapshots/1/snapshot/etc/snapper/configs" "$BACKEND_TOP/@/.snapshots/1/snapshot/.snapshots"
  printf 'UUID=test / btrfs subvol=@ 0 0\n' >"$BACKEND_TOP/@/.snapshots/1/snapshot/etc/fstab"
  printf 'SUBVOLUME="/"\nFSTYPE="btrfs"\nNUMBER_LIMIT="7"\n' >"$BACKEND_TOP/@/.snapshots/1/snapshot/etc/snapper/configs/root"
  echo history-one >"$BACKEND_TOP/@/.snapshots/1/info.xml"
}
# Receipt ownership is checked in production. This fixture runs unprivileged;
# delegate only the receipt uid probe, preserving all parser/type/mode checks.
stat() {
  if [[ $* == '-c %u '* ]]; then echo 0; else command stat "$@"; fi
}
new_fixture success
backend_restore @/.snapshots/1/snapshot 123
[[ $(backend_uuid "$BACKEND_TOP/@") == "$NEW_UUID" && $(backend_uuid "$BACKEND_TOP/@old-123") == "$ROOT_UUID" ]] || fail 'root exchange'
[[ $(backend_uuid "$BACKEND_TOP/@/.snapshots") == "$HISTORY_UUID" && $TEST_ATTACHED == "$HISTORY_UUID" ]] || fail 'exact backend transfer and temporary attachment'
[[ $(cat "$BACKEND_TOP/@/.snapshots/1/info.xml") == history-one ]] || fail 'history metadata retained'
[[ ! -e $BACKEND_RECEIPT && ! -e $BACKEND_TOP/@old-123/.snapshots/.uuid ]] || fail 'no external persistent backend'
pass 'restore transfers exact nested history and retains old root'

for move in 1 2 3; do
  new_fixture "failure-$move"
  FAIL_MOVE=$move
  if backend_restore @/.snapshots/1/snapshot 123; then fail 'injected move failed'; fi
  FAIL_MOVE=0
  backend_recover_transaction
  [[ $(backend_uuid "$BACKEND_TOP/@") == "$ROOT_UUID" && $(backend_uuid "$BACKEND_TOP/@/.snapshots") == "$HISTORY_UUID" ]] || fail 'rollback restores original identities'
  [[ ! -e $BACKEND_TOP/@new && ! -e $BACKEND_RECEIPT ]] || fail 'own empty staging cleaned'
  [[ $(cat "$BACKEND_TOP/@/.snapshots/1/info.xml") == history-one ]] || fail 'rollback retains history'
  pass "move $move failure recovers without deleting history"
done
new_fixture attachment-failure
FAIL_MOUNT=1
if backend_restore @/.snapshots/1/snapshot 123; then fail 'attachment must fail'; fi
backend_recover_transaction
[[ $(backend_uuid "$BACKEND_TOP/@") == "$ROOT_UUID" && $(backend_uuid "$BACKEND_TOP/@/.snapshots") == "$HISTORY_UUID" ]] || fail 'failed attachment rolls roots and history back'
pass 'failed live attachment restores running root backend'

for conflict in target-mount target-config duplicate-config target-backend target-symlink existing-new existing-old; do
  new_fixture "$conflict"
  target="$BACKEND_TOP/@/.snapshots/1/snapshot"
  case "$conflict" in
    target-mount) echo 'UUID=custom /.snapshots btrfs subvol=custom 0 0' >>"$target/etc/fstab";;
    target-config) echo 'SUBVOLUME="/home"' >"$target/etc/snapper/configs/root";;
    duplicate-config) echo 'SUBVOLUME="/home"' >>"$target/etc/snapper/configs/root";;
    target-backend) echo private >"$target/.snapshots/keep";;
    target-symlink) rmdir "$target/.snapshots"; ln -s /unrelated "$target/.snapshots";;
    existing-new) mkdir "$BACKEND_TOP/@new";;
    existing-old) mkdir "$BACKEND_TOP/@old-123";;
  esac
  if backend_restore @/.snapshots/1/snapshot 123; then fail "refuse $conflict"; fi
  [[ $MOVE_NUMBER == 0 && ! -e $BACKEND_RECEIPT && $(backend_uuid "$BACKEND_TOP/@/.snapshots") == "$HISTORY_UUID" ]] || fail 'conflict preflight has no history mutation'
  pass "$conflict preserves prior state"
done

new_fixture baseline
mkdir -p "$BACKEND_TOP/@factory/etc"
echo 'UUID=test / btrfs subvol=@ 0 0' >"$BACKEND_TOP/@factory/etc/fstab"
echo "$SNAPSHOT_UUID" >"$BACKEND_TOP/@factory/.uuid"
backend_restore @factory 123
[[ ! -e $BACKEND_TOP/@/etc/snapper/configs/root && $(backend_uuid "$BACKEND_TOP/@/.snapshots") == "$HISTORY_UUID" ]] || fail 'baseline preserves history without inventing configuration'
pass 'baseline without Snapper config remains supported'

for kind in proven ambiguous unmatched nonempty symlink plain-container; do
  new_fixture "repair-$kind"
  fixture_volume "$BACKEND_TOP/@old-100" "$NEW_UUID"
  "$real_mv" "$BACKEND_TOP/@/.snapshots" "$BACKEND_TOP/@old-100/.snapshots"
  mkdir "$BACKEND_TOP/@/.snapshots"
  echo "$SNAPSHOT_UUID" >"$BACKEND_TOP/@/.parent"
  case "$kind" in
    ambiguous) cp -a "$BACKEND_TOP/@old-100" "$BACKEND_TOP/@old-200"; echo "$NEW_UUID" >"$BACKEND_TOP/@old-200/.snapshots/.uuid";;
    unmatched) echo "$NEW_UUID" >"$BACKEND_TOP/@/.parent";;
    plain-container) rm "$BACKEND_TOP/@old-100/.uuid";;
    nonempty) touch "$BACKEND_TOP/@/.snapshots/keep";;
    symlink) rmdir "$BACKEND_TOP/@/.snapshots"; ln -s /unrelated "$BACKEND_TOP/@/.snapshots";;
  esac
  if [[ $kind == proven ]]; then
    backend_repair
    [[ $(backend_uuid "$BACKEND_TOP/@/.snapshots") == "$HISTORY_UUID" ]] || fail 'proven backend reattached'
    backend_repair
    [[ $MOVE_NUMBER == 1 ]] || fail 'repeat repair idempotent'
  else
    if backend_repair; then fail "$kind must refuse"; fi
    [[ $MOVE_NUMBER == 0 ]] || fail 'unproven state untouched'
  fi
  pass "$kind ancestry repair contract"
done

new_fixture changed-receipt
FAIL_MOVE=1
backend_restore @/.snapshots/1/snapshot 123 >/dev/null 2>&1 || true
FAIL_MOVE=0
printf '%s\n' "$SNAPSHOT_UUID" >"$BACKEND_TOP/@new/.uuid"
if backend_recover_transaction; then fail 'changed staged identity refuses'; fi
[[ -e $BACKEND_RECEIPT && $(backend_uuid "$BACKEND_TOP/@/.snapshots") == "$HISTORY_UUID" ]] || fail 'receipt failure retains history and evidence'
pass 'changed transaction identity preserves evidence for manual inspection'

# Real service calls are covered in the guest. This fixture verifies policy
# ownership on success and refusal, including pre-existing runtime masks.
systemctl() {
  printf '%s\n' "$*" >>"$SERVICE_LOG"
  local unit=${2:-}
  case "$1" in
    show)
      if [[ $3 == --property=LoadState ]]; then echo loaded
      elif [[ ${TEST_BUSY:-0} == 1 && $unit == snapper-cleanup.service ]]; then echo active
      else echo inactive; fi ;;
    is-enabled) [[ $unit != snapper-boot.service ]] || { echo masked-runtime; return; }; echo static ;;
    is-active) [[ ${3:-} == snapper-cleanup.timer || ${3:-} == snapperd.service ]] ;;
    mask) [[ ${FAIL_MASK:-0} != 1 || $3 != snapper-timeline.service ]] ;;
    stop|start|unmask) : ;;
    *) return 99 ;;
  esac
}
pgrep() { return 1; }
sleep() { SECONDS=$((SECONDS + 31)); }
for scenario in success busy mask-failure; do
  SERVICE_LOG="$test_tmp/services-$scenario"
  BACKEND_MASKED=() BACKEND_TIMERS=() BACKEND_DAEMON=0 TEST_BUSY=0 FAIL_MASK=0
  [[ $scenario != busy ]] || TEST_BUSY=1
  [[ $scenario != mask-failure ]] || FAIL_MASK=1
  result=0
  backend_quiesce || result=$?
  backend_resume_services
  if [[ $scenario == success ]]; then
    (( result == 0 )) || fail 'idle services permit maintenance'
    grep -Fx 'stop snapperd.service' "$SERVICE_LOG" >/dev/null || fail 'idle daemon stopped'
    grep -Fx 'start snapperd.service' "$SERVICE_LOG" >/dev/null || fail 'prior daemon restored'
  else (( result != 0 )) || fail 'busy/failure refuses maintenance'; fi
  ! grep -Fx 'unmask --runtime snapper-boot.service' "$SERVICE_LOG" || fail 'pre-existing mask preserved'
  ! grep -E '^stop snapper-(cleanup|timeline|boot|backup)\.service$' "$SERVICE_LOG" || fail 'in-flight writer never killed'
  ! grep -E '^(enable|disable)' "$SERVICE_LOG" || fail 'persistent service policy unchanged'
  pass "$scenario restores only owned service state"
done

for identity in @ @/.snapshots @new; do
  new_fixture "identity-${identity//\//-}"
  FAIL_UUID="$BACKEND_TOP/$identity"
  if backend_restore @/.snapshots/1/snapshot 123; then fail 'identity failure refuses'; fi
  FAIL_UUID=""
  [[ $MOVE_NUMBER == 0 && ! -e $BACKEND_RECEIPT && $(backend_uuid "$BACKEND_TOP/@/.snapshots") == "$HISTORY_UUID" ]] || fail 'identity failure cannot move history or publish invalid receipt'
  pass "$identity identity failure precedes dependent mutation"
done
new_fixture unquoted-config
printf '  SUBVOLUME = / # root\nFSTYPE = btrfs\nNUMBER_LIMIT="7"\n' >"$BACKEND_TOP/@/.snapshots/1/snapshot/etc/snapper/configs/root"
backend_restore @/.snapshots/1/snapshot 123
pass 'valid whitespace and unquoted root config preserved'

# Optional-history mode covers genuinely unconfigured baseline restores.
# .uuid is test-only subvolume metadata, excluded from the emptiness predicate.
backend_empty_dir() { backend_plain_dir "$1" && [[ -z $(find "$1" -mindepth 1 -maxdepth 1 ! -name .uuid -print -quit) ]]; }
btrfs() {
  case "$1 $2" in
    'subvolume snapshot') cp -a "$3" "$4"; echo "$NEW_UUID" >"$4/.uuid";;
    'subvolume create') fixture_volume "$3" "$HISTORY_UUID";;
    'subvolume delete')
      if [[ $3 == */.snapshots ]]; then
        [[ $(backend_uuid "$3") == "$HISTORY_UUID" ]] && backend_empty_dir "$3" || return 79
      else
        [[ $(backend_uuid "$3") == "$NEW_UUID" && ! -f $3/.snapshots/.uuid ]] || return 78
      fi
      rm -r "$3";;
    *) return 99;;
  esac
}
for configured in yes no; do
  for outcome in success rollback; do
    new_fixture "no-history-$configured-$outcome"
    cp -a "$BACKEND_TOP/@/.snapshots/1/snapshot" "$BACKEND_TOP/@fresh"
    [[ $configured == yes ]] || rm "$BACKEND_TOP/@fresh/etc/snapper/configs/root"
    rm -r "$BACKEND_TOP/@/.snapshots"
    BACKEND_NO_HISTORY=1
    if [[ $outcome == rollback ]]; then
      FAIL_MOVE=1
      if backend_restore @fresh 123; then fail 'no-history move must fail'; fi
      FAIL_MOVE=0
      backend_recover_transaction
      [[ $(backend_uuid "$BACKEND_TOP/@") == "$ROOT_UUID" && ! -e $BACKEND_TOP/@/.snapshots && ! -e $BACKEND_TOP/@new ]] || fail 'no-history rollback preserves absent backend'
    else
      backend_restore @fresh 123
      if [[ $configured == yes ]]; then
        [[ $(backend_uuid "$BACKEND_TOP/@/.snapshots") == "$HISTORY_UUID" && $(command stat -c %a "$BACKEND_TOP/@/.snapshots") == 750 ]] || fail 'existing baseline config gets new private empty backend'
      else
        [[ ! -e $BACKEND_TOP/@/etc/snapper/configs/root && ! -e $BACKEND_TOP/@/.snapshots/.uuid ]] || fail 'unconfigured baseline stays unconfigured'
      fi
    fi
    pass "no-history $configured config $outcome"
  done
done

SERVICE_LOG="$test_tmp/services-resume"
BACKEND_SERVICE_RECEIPT="$test_tmp/service-receipt"
BACKEND_MASKED=() BACKEND_TIMERS=() BACKEND_DAEMON=0 TEST_BUSY=0 FAIL_MASK=0
(umask 077; printf 'mask snapper-cleanup.service\ntimer snapper-cleanup.timer\n' >"$BACKEND_SERVICE_RECEIPT")
backend_service_recover
[[ ! -e $BACKEND_SERVICE_RECEIPT ]] || fail 'owned service intent cleared after restoration'
grep -Fx 'unmask --runtime snapper-cleanup.service' "$SERVICE_LOG" >/dev/null || fail 'interrupted own mask restored'
grep -Fx 'start snapper-cleanup.timer' "$SERVICE_LOG" >/dev/null || fail 'interrupted own timer restored'
(umask 077; printf 'mask unrelated.service\n' >"$BACKEND_SERVICE_RECEIPT")
if backend_service_recover; then fail 'ambiguous service receipt refuses'; fi
[[ -e $BACKEND_SERVICE_RECEIPT ]] || fail 'ambiguous service intent retained'
pass 'service intent retry restores owned changes and rejects unrelated state'
pgrep() { return 2; }
if backend_busy; then pass 'pgrep error refuses to claim idle writers'; else fail 'pgrep error must fail closed'; fi
new_fixture dangling-receipt
ln -s missing "$BACKEND_RECEIPT"
if (
  BACKEND_QUIESCED=1 BACKEND_MOUNT_READY=1
  backend_resume_services() { touch "$test_tmp/unsafe-service-resume"; }
  umount() { :; }
  backend_cleanup
); then fail 'dangling receipt must fail cleanup'; fi
[[ -L $BACKEND_RECEIPT && ! -e $test_tmp/unsafe-service-resume ]] || fail 'dangling receipt retains inspection and writer gate'
pass 'dangling receipt never resumes writers after failed reconciliation'
