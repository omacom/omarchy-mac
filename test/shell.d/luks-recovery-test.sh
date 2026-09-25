#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# prepare_luks_recovery against a slot-table cryptsetup. The kill-at-every-step
# runs on real LUKS2 and LUKS1 volumes are in luks-rekey-journal-test.sh.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
PROVISIONING_DIR="$test_tmp/provisioning"
REKEY_STATE="$PROVISIONING_DIR/rekey.state"
LOG_FILE="$test_tmp/log"
slots="$test_tmp/slots"
calls="$test_tmp/calls"
device=fixture-device
password=fixture-owner
log_step() { printf '%s\n' "$*" >>"$LOG_FILE"; }
say() { :; }
# No hardware detector, boot module, real device, or elevated command is present.
source "$ROOT/install/provisioning/luks-rekey.sh"
source "$ROOT/install/provisioning/luks-recovery.sh"

cryptsetup() {
  local operation=$1 key_file="" requested="" material slot newfile="" target=""
  shift
  printf '%s\n' "$operation" >>"$calls"
  while (( $# )); do
    case $1 in
      --key-file) key_file=$2; shift 2 ;;
      --key-slot) requested=$2; shift 2 ;;
      --token-type) shift 2 ;;
      --*|-q) shift ;;
      *)
        if [[ -z $target ]]; then target=$1; else newfile=$1; fi
        shift
        ;;
    esac
  done
  [[ $target == "$device" ]] || return 1
  if [[ $operation == "luksDump" ]]; then
    [[ ! -e $test_tmp/dump-fail ]] || return 1
    echo "Keyslots:"
    awk '{printf "  %s: luks2\n", $1}' "$slots"
    return
  fi
  material=$(cat "$key_file") || return 1
  slot=$(awk -v key="$material" '$2 == key {print $1; exit}' "$slots")
  [[ -n $slot ]] || return 1
  case $operation in
    open) printf 'Key slot %s unlocked\n' "$slot" ;;
    luksAddKey)
      [[ ! -e $test_tmp/add-fail ]] || { echo 'fixture add failure' >&2; return 1; }
      rekey_state_get recovery_shown >"$test_tmp/shown-at-add" || : >"$test_tmp/shown-at-add"
      material=$(cat "$newfile") || return 1
      if [[ -z $requested ]]; then
        for (( requested=0; requested<32; requested++ )); do
          if ! awk '{print $1}' "$slots" | grep -Fxq "$requested"; then break; fi
        done
      fi
      ! awk '{print $1}' "$slots" | grep -Fxq "$requested" || return 1
      printf '%s %s\n' "$requested" "$material" >>"$slots"
      ;;
    luksKillSlot)
      awk -v slot="$newfile" '$1 != slot' "$slots" >"$slots.next"
      mv "$slots.next" "$slots"
      ;;
    *) return 1 ;;
  esac
}

show_recovery_key() {
  [[ $(luks_slot_for "$1" "$device") == "$(rekey_state_get recovery_slot)" ]] || fail "display before key verification"
  [[ $(rekey_state_get recovery_shown) == "0" ]] || fail "the key is journaled as added before it is shown"
  printf '%s %s\n' "$RECOVERY_REPLACED" "$1" >>"$test_tmp/shown"
  [[ ! -e $test_tmp/display-fail ]]
}

# After a factory reset: the staged key in slot 0 beside a previous owner's key.
fixture() {
  rm -rf "$PROVISIONING_DIR" "$test_tmp/shown" "$test_tmp"/*-fail
  mkdir -p "$PROVISIONING_DIR"
  printf fixture-staged >"$PROVISIONING_DIR/luks-key"
  printf '0 fixture-staged\n1 previous-owner\n' >"$slots"
  : >"$calls" >"$LOG_FILE"
  recovery_key=""
  unset OMARCHY_PROVISION_WORKER
}

shown_count() {
  [[ -e $test_tmp/shown ]] && wc -l <"$test_tmp/shown" || echo 0
}

key=$(generate_recovery_passphrase)
luks_recovery_passphrase "$key" || fail "a generated key has the recovery key's form"
! luks_recovery_passphrase "fixture-owner" && ! luks_recovery_passphrase "${key,,}" && ! luks_recovery_passphrase "$key-AAAA" ||
  fail "other passwords do not have the recovery key's form"
[[ $(generate_recovery_passphrase) != "$key" ]] || fail "each recovery key is new"
pass "recovery keys are 48 base32 characters in groups of four, and recognisable by that form"

fixture
prepare_luks_recovery "$device"
recovery_slot=$(rekey_state_get recovery_slot)
[[ $recovery_slot == "2" && $(luks_slot_for "$recovery_key" "$device") == "2" ]] || fail "the key goes to the first free slot" "$(cat "$slots")"
[[ $(rekey_state_get recovery_shown) == "1" && $(shown_count) == "1" ]] || fail "the key is shown once and its acknowledgement journaled"
[[ $(grep -c luksAddKey "$calls") == "1" ]] || fail "one key is added"
[[ -z $(rekey_state_get owner_slot || true) && -z $(luks_slot_for "$password" "$device") ]] ||
  fail "the owner's slot is left to the re-key"
[[ $(stat -c %a "$REKEY_STATE") == "600" ]] || fail "the journal is private"
! grep -Fq -e "$recovery_key" -e fixture-staged "$REKEY_STATE" "$LOG_FILE" || fail "no key reaches the journal or the log"
prepare_luks_recovery "$device"
[[ $(shown_count) == "1" && $(grep -c luksAddKey "$calls") == "1" && $RECOVERY_REPLACED == "0" ]] ||
  fail "a retry keeps the acknowledged key without showing it again"
pass "the recovery key is added with the staged key, verified, shown once and kept once acknowledged"

# Shown but never acknowledged: the owner may have written it down, so the
# retry replaces it in the same slot and says so.
fixture
touch "$test_tmp/display-fail"
if prepare_luks_recovery "$device"; then fail "a display that is not acknowledged fails the attempt"; fi
unconfirmed_key=$recovery_key
recovery_slot=$(rekey_state_get recovery_slot)
[[ $(rekey_state_get recovery_shown) == "0" ]] || fail "an unacknowledged key is journaled as shown, not acknowledged"
rm "$test_tmp/display-fail"
prepare_luks_recovery "$device"
[[ $RECOVERY_REPLACED == "1" && $(tail -n 1 "$test_tmp/shown") == "1 $recovery_key" ]] || fail "the replacement tells the owner to replace their copy"
[[ -z $(luks_slot_for "$unconfirmed_key" "$device") ]] || fail "the unacknowledged key no longer unlocks"
[[ $(luks_slot_for "$recovery_key" "$device") == "$recovery_slot" && $(rekey_state_get recovery_slot) == "$recovery_slot" ]] ||
  fail "the replacement reuses the reserved slot"
pass "an unacknowledged recovery key is revoked and replaced in its slot, and the owner told"

# Added but never shown (killed before the journal said so): replaced silently.
fixture
printf '2 never-shown\n' >>"$slots"
printf 'recovery_slot=2\n' >"$REKEY_STATE"
chmod 600 "$REKEY_STATE"
prepare_luks_recovery "$device"
[[ $RECOVERY_REPLACED == "0" && -z $(luks_slot_for never-shown "$device") && $(luks_slot_for "$recovery_key" "$device") == "2" ]] ||
  fail "a key never shown is replaced without a warning" "$(cat "$slots")"
pass "a recovery key added but never shown is replaced without asking the owner to replace a copy"

# The reserved slot never takes the staged or an owner's slot.
fixture
printf 'recovery_slot=0\nowner_slot=1\n' >"$REKEY_STATE"
chmod 600 "$REKEY_STATE"
prepare_luks_recovery "$device"
[[ $(rekey_state_get recovery_slot) == "2" && -n $(luks_slot_for fixture-staged "$device") && -n $(luks_slot_for previous-owner "$device") ]] ||
  fail "a recorded slot that holds the staged or the owner's key is never revoked" "$(cat "$slots")"
pass "a recovery slot that names the staged or the owner's slot is reserved afresh"

# An acknowledged slot that went missing is replaced, and the owner told. The
# journal stops calling it acknowledged before the new key goes in, so a retry
# after a kill there never keeps a key the owner has not seen.
fixture
printf 'recovery_slot=5\nrecovery_shown=1\n' >"$REKEY_STATE"
chmod 600 "$REKEY_STATE"
touch "$test_tmp/display-fail"
if prepare_luks_recovery "$device"; then fail "an unacknowledged replacement fails the attempt"; fi
[[ $(<"$test_tmp/shown-at-add") != "1" && $(rekey_state_get recovery_shown) == "0" ]] ||
  fail "the replacement is not journaled as acknowledged when it is added"
unseen_key=$recovery_key
rm "$test_tmp/display-fail"
prepare_luks_recovery "$device"
[[ $RECOVERY_REPLACED == "1" && $(luks_slot_for "$recovery_key" "$device") == "5" && -z $(luks_slot_for "$unseen_key" "$device") ]] ||
  fail "a missing acknowledged key is replaced until the owner acknowledges the replacement"
grep -q 'acknowledged recovery slot 5 is missing' "$LOG_FILE" || fail "the log says why"
pass "an acknowledged recovery slot missing from the header is replaced, and the owner told, until they acknowledge the new key"

# A header that cannot be read never passes for a missing acknowledged key.
fixture
printf '2 acknowledged-key\n' >>"$slots"
printf 'recovery_slot=2\nrecovery_shown=1\n' >"$REKEY_STATE"
chmod 600 "$REKEY_STATE"
touch "$test_tmp/dump-fail"
if prepare_luks_recovery "$device"; then fail "an unreadable header fails the recovery step"; fi
rm "$test_tmp/dump-fail"
[[ $(rekey_state_get recovery_shown) == "1" && $(luks_slot_for acknowledged-key "$device") == "2" && $(shown_count) == "0" ]] ||
  fail "an unreadable header leaves the acknowledged key and its journal alone"
prepare_luks_recovery "$device"
[[ $(shown_count) == "0" && $(luks_slot_for acknowledged-key "$device") == "2" ]] || fail "the next attempt keeps the acknowledged key"
pass "a header that cannot be read fails the recovery step and keeps the acknowledged key"

fixture
printf 'nothing' >"$PROVISIONING_DIR/luks-key"
if prepare_luks_recovery "$device"; then fail "a staged key that opens nothing fails the recovery step"; fi
[[ $(wc -l <"$slots") == "2" && $(shown_count) == "0" ]] || fail "nothing is added or shown without the staged key"
pass "the recovery key is added only while the staged key still opens the disk"

fixture
touch "$test_tmp/add-fail"
if prepare_luks_recovery "$device"; then fail "key creation failure must propagate"; fi
[[ $(shown_count) == "0" ]] || fail "failed key creation must never display key"
grep -Fq 'fixture add failure' "$LOG_FILE" || fail "key creation diagnostics retained"
pass "failed key creation is diagnosable and never displays an unusable key"

fixture
OMARCHY_PROVISION_WORKER=1
if prepare_luks_recovery "$device"; then fail "background worker must not prepare recovery display"; fi
[[ $(wc -l <"$slots") == "2" && ! -e $REKEY_STATE ]] || fail "the worker changes nothing"
pass "recovery preparation is restricted to the foreground caller"
