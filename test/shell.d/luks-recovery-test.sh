#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
PROVISIONING_DIR="$test_tmp/provisioning"
REKEY_STATE="$PROVISIONING_DIR/rekey.state"
LOG_FILE="$test_tmp/log"
slots="$test_tmp/slots"
calls="$test_tmp/calls"
device=fixture-device
password=fixture-owner
mkdir -p "$PROVISIONING_DIR"
printf fixture-staged >"$PROVISIONING_DIR/luks-key"
printf '0 fixture-staged\n' >"$slots"
: >"$calls"
log_step() { printf '%s\n' "$*" >>"$LOG_FILE"; }
say() { :; }
# No hardware detector, boot module, real device, or elevated command is present.
source "$ROOT/install/provisioning/luks-rekey.sh"
source "$ROOT/install/provisioning/luks-recovery.sh"

cryptsetup() {
  local operation=$1 key_file="" requested="" argument material slot newfile="" target=""
  shift
  printf '%s\n' "$operation" >>"$calls"
  while (( $# )); do
    case $1 in
      --key-file) key_file=$2; shift 2 ;;
      --key-slot) requested=$2; shift 2 ;;
      --*|-q) shift ;;
      *)
        if [[ -z $target ]]; then target=$1; else newfile=$1; fi
        shift
        ;;
    esac
  done
  [[ $target == "$device" ]] || return 1
  if [[ $operation == "luksDump" ]]; then
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
      material=$(cat "$newfile") || return 1
      if [[ -z $requested ]]; then
        for (( requested=0; requested<32; requested++ )); do
          if ! awk '{print $1}' "$slots" | grep -Fxq "$requested"; then break; fi
        done
      fi
      printf '%s %s\n' "$requested" "$material" >>"$slots"
      ;;
    luksKillSlot)
      awk -v slot="$newfile" '$1 != slot' "$slots" >"$slots.next"
      mv "$slots.next" "$slots"
      ;;
    *) return 1 ;;
  esac
}

key=$(generate_recovery_passphrase)
[[ $key =~ ^([A-Z2-7]{4}-){11}[A-Z2-7]{4}$ ]] || fail "recovery key format"
owner_slot=$(luks_ensure_slot "$password" "$device" owner_slot)
[[ $owner_slot == "1" ]] || fail "owner slot created"
[[ $(luks_ensure_slot "$password" "$device" owner_slot) == "$owner_slot" ]] || fail "owner slot reused"
[[ $(grep -c luksAddKey "$calls") == "1" ]] || fail "retry added a duplicate owner slot"
if luks_ensure_slot wrong-password "$device" owner_slot; then fail "owner retry must authenticate"; fi
[[ $(stat -c %a "$REKEY_STATE") == "600" ]] || fail "journal must be private"
pass "shared owner slot creation is idempotent and retry authenticates"

show_recovery_key() {
  [[ $(luks_slot_for "$1" "$device") == "$(rekey_state_get recovery_slot)" ]] || fail "display before key verification"
  printf 'shown\n' >>"$test_tmp/shown"
  [[ ! -e $test_tmp/display-fail ]]
}
prepare_luks_recovery "$device"
recovery_slot=$(rekey_state_get recovery_slot)
[[ $(rekey_state_get recovery_shown) == "1" ]] || fail "acknowledgement persisted"
[[ $(wc -l <"$test_tmp/shown") == "1" ]] || fail "key displayed once"
prepare_luks_recovery "$device"
[[ $(wc -l <"$test_tmp/shown") == "1" ]] || fail "acknowledged key redisplayed"
! grep -Fq "$password" "$REKEY_STATE" || fail "journal leaked owner secret"
! grep -Fq "$recovery_key" "$REKEY_STATE" || fail "journal leaked recovery secret"
pass "recovery display follows slot verification and acknowledged retries retain it"

rekey_state_put recovery_shown 0
touch "$test_tmp/display-fail"
if prepare_luks_recovery "$device"; then fail "display failure must propagate"; fi
unconfirmed_key=$recovery_key
rm "$test_tmp/display-fail"
prepare_luks_recovery "$device"
[[ $RECOVERY_REPLACED == "1" ]] || fail "interrupted display reports replacement"
[[ -z $(luks_slot_for "$unconfirmed_key" "$device") ]] || fail "unconfirmed recovery key still unlocks"
[[ $(rekey_state_get recovery_slot) == "$recovery_slot" ]] || fail "replacement must reuse reserved slot"
pass "interrupted recovery confirmation revokes the old credential before replacement"

luks_kill_other_slots "$device" "$password" "$owner_slot" "$recovery_slot"
[[ $(luks_dump_slots "$device" | sort) == $(printf '%s\n' "$owner_slot" "$recovery_slot" | sort) ]] || fail "only selected slots should survive"
pass "slot retirement preserves both owner and recovery credentials"

rekey_state_put recovery_shown 0
shown_before=$(wc -l <"$test_tmp/shown")
touch "$test_tmp/add-fail"
if prepare_luks_recovery "$device"; then fail "key creation failure must propagate"; fi
[[ $(wc -l <"$test_tmp/shown") == "$shown_before" ]] || fail "failed key creation must never display key"
grep -Fq 'fixture add failure' "$LOG_FILE" || fail "key creation diagnostics retained"
pass "failed key creation is diagnosable and never displays an unusable key"

OMARCHY_PROVISION_WORKER=1
if prepare_luks_recovery "$device"; then fail "background worker must not prepare recovery display"; fi
pass "recovery preparation is restricted to the foreground caller"
