#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/install/helpers/owner-rekey.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stat() { if [[ $* == '-c %u '* ]]; then echo 0; else command stat "$@"; fi; }
sync() { :; }
owner_rekey_device_valid() { [[ $1 == /fixture-luks ]]; }
reset_boot_probe() { [[ ${FAIL_PROBE:-0} == 0 ]]; }
owner_rekey_slots() { find "$HEADER" -name 'slot-*' -printf '%f\n' | sed 's/slot-//' | sort -n; }
owner_rekey_remove_auto_unlock() { echo remove >>"$EVENTS"; }
owner_rekey_boot_prepare() {
  echo boot >>"$EVENTS"
  [[ $FAIL_BOOT == 0 ]] || return 73
  printf 'fixture-published-boot\n' >"$1/boot-manifest"
  chmod 600 "$1/boot-manifest"
}
owner_rekey_boot_check() { [[ -f $1/boot-manifest && $(cat "$1/boot-manifest") == fixture-published-boot ]]; }
cryptsetup() {
  local operation=$1 key_file="" slot="" value argument
  shift
  case $operation in
    luksUUID) echo "$DEVICE_UUID"; return ;;
    open)
      while (( $# )); do
        argument=$1; shift
        case $argument in --key-file) key_file=$1; shift;; --key-slot) slot=$1; shift;; esac
      done
      value=$(cat "$key_file")
      if [[ -n $slot ]]; then [[ -f $HEADER/slot-$slot && $(cat "$HEADER/slot-$slot") == "$value" ]];
      else grep -lFx -- "$value" "$HEADER"/slot-* >/dev/null; fi ;;
    luksAddKey)
      [[ $1 == --key-file && $(cat "$2") == staged ]] || return 74
      printf '%s' "$(cat "$4")" >"$HEADER/slot-2"
      echo add >>"$EVENTS" ;;
    luksKillSlot)
      [[ $1 == -q && $2 == --key-file && $(cat "$3") == owner ]] || return 75
      slot=$5
      echo "kill-$slot" >>"$EVENTS"
      [[ $FAIL_KILL != "$slot" ]] || return 76
      rm "$HEADER/slot-$slot" ;;
    *) return 99 ;;
  esac
}
new_fixture() {
  local base="$test_tmp/$1"
  mkdir -p "$base/header"
  HEADER="$base/header" STATE="$base/state" EVENTS="$base/events" STAGED="$base/staged" OWNER="$base/owner"
  echo staged >"$HEADER/slot-0"; echo seller >"$HEADER/slot-1"
  echo staged >"$STAGED"; echo owner >"$OWNER"; chmod 600 "$STAGED" "$OWNER"
  : >"$EVENTS"; FAIL_BOOT=0 FAIL_KILL=""
  DEVICE_UUID=11111111-1111-1111-1111-111111111111
}
new_fixture partial
FAIL_KILL=1
if owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"; then fail 'partial retirement failure'; fi
[[ ! -f $HEADER/slot-0 && -f $HEADER/slot-1 && -f $HEADER/slot-2 && -f $STAGED ]] || fail 'throwaway removed, owner and pending retained'
[[ $(cut -d' ' -f4 "$STATE/receipt") == boot-published ]] || fail 'published receipt preserved'
FAIL_KILL=""
owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"
[[ $(owner_rekey_slots /fixture-luks) == 2 && ! -e $STAGED ]] || fail 'owner-only final slots'
[[ $(grep -c '^boot$' "$EVENTS") == 1 && $(grep -c '^add$' "$EVENTS") == 1 ]] || fail 'retry does not regenerate or add needless key'
pass 'partial retirement after throwaway removal resumes through owner credential'
removals_before=$(grep -c '^remove$' "$EVENTS")
owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"
[[ $(grep -c '^remove$' "$EVENTS") == $((removals_before + 1)) ]] || fail 'completed retry repeats auto-unlock cleanup'
pass 'completed receipt is idempotent with absent staged key'
new_fixture missing
FAIL_KILL=1
if owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"; then fail 'injected failure'; fi
rm "$STAGED"; FAIL_KILL=""
owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"
[[ $(owner_rekey_slots /fixture-luks) == 2 ]] || fail 'missing staged key must not bypass remaining retirement'
pass 'missing throwaway file does not skip pending retirement'
new_fixture wrong
FAIL_KILL=1
if owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"; then fail 'injected failure'; fi
cp "$EVENTS" "$test_tmp/events-before"
echo wrong >"$OWNER"
if owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"; then fail 'wrong owner retry'; fi
cmp "$EVENTS" "$test_tmp/events-before" || fail 'wrong credential mutates neither boot nor slots'
pass 'wrong owner credential fails before mutation'
new_fixture swapped
FAIL_KILL=1
if owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"; then fail 'injected failure'; fi
cp "$EVENTS" "$test_tmp/events-before"
DEVICE_UUID=22222222-2222-2222-2222-222222222222
if owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"; then fail 'different LUKS identity'; fi
cmp "$EVENTS" "$test_tmp/events-before" || fail 'device mismatch mutates neither boot nor slots'
pass 'device substitution refuses prior receipt'
new_fixture boot_fail
FAIL_BOOT=1
if owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"; then fail 'boot failure'; fi
[[ $(owner_rekey_slots /fixture-luks | wc -l) == 3 && -f $STAGED ]] || fail 'no retirement before verified boot'
FAIL_BOOT=0
owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"
[[ $(grep -c '^add$' "$EVENTS") == 1 ]] || fail 'generation retry preserves existing owner slot'
pass 'boot failure retains all recovery slots and retries same owner slot'

new_fixture unsupported
FAIL_PROBE=1
if owner_rekey_run /fixture-luks "$STAGED" "$OWNER" "$STATE"; then fail 'unsupported boot preflight'; fi
[[ ! -s $EVENTS && $(owner_rekey_slots /fixture-luks | wc -l) == 2 ]] || fail 'unsupported boot mutated header/config'
pass 'owner boot preflight precedes key addition and config mutation'
