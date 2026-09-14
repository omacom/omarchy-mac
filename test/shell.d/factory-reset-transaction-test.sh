#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/install/helpers/factory-reset.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stat() { if [[ $* == '-c %u '* ]]; then echo 0; else command stat "$@"; fi; }
sync() { :; }
reset_uuid() { [[ ! -L $1 && -f $1/.uuid ]] && cat "$1/.uuid"; }
findmnt() { echo "$RESET_TXN_FS"; }
fixture_volume() { mkdir -p "$1"; echo "$2" >"$1/.uuid"; }
reset_boot_rollback() { [[ $1 == "$STATE/boot" && $2 == provision ]] || return 1; echo restored >"$STATE/boot-verdict"; }
reset_default_uuid() { printf '%s\n' "$DEFAULT_UUID"; }
reset_default_set() { [[ $1 == "$TOP" && $3 == "$TOP/@" && $(reset_uuid "$3") == "$2" ]] || return 1; DEFAULT_UUID=$2; }
reset_default_set_top() { [[ $1 == "$TOP" ]] || return 1; DEFAULT_UUID=-; }
reset_default_restore() {
  [[ $1 == "$TOP" && $2 == "$RESET_TXN_DEFAULT" && $3 == "$RESET_TXN_DEFAULT_PATH" ]] || return 1
  if [[ $2 == - ]]; then DEFAULT_UUID=-; else [[ $(reset_uuid "$TOP/$3") == "$2" ]] || return 1; DEFAULT_UUID=$2; fi
}
new_fixture() {
  TOP="$test_tmp/$1" STATE="$test_tmp/$1/.journal"
  mkdir -p "$TOP"; mkdir -m 700 "$STATE"
  RESET_TXN_FS=11111111-1111-1111-1111-111111111111 RESET_TXN_STAMP=123
  RESET_TXN_ROOT=22222222-2222-2222-2222-222222222222 RESET_TXN_FACTORY=33333333-3333-3333-3333-333333333333
  RESET_TXN_NEXT=44444444-4444-4444-4444-444444444444 RESET_TXN_CLEAN=55555555-5555-5555-5555-555555555555
  RESET_TXN_DEFAULT=$RESET_TXN_ROOT RESET_TXN_DEFAULT_PATH=@ DEFAULT_UUID=$RESET_TXN_ROOT
  fixture_volume "$TOP/@" "$RESET_TXN_ROOT"
  fixture_volume "$TOP/@factory" "$RESET_TXN_FACTORY"
  fixture_volume "$TOP/@omarchy-reset-next" "$RESET_TXN_NEXT"
  fixture_volume "$TOP/@omarchy-reset-factory" "$RESET_TXN_CLEAN"
  reset_transaction_record "$STATE"
  mkdir "$STATE/boot"
  reset_state_write "$STATE/boot/publication" published
}
for boundary in 0 1 2 3 4; do
  new_fixture "move-$boundary"
  if (( boundary >= 1 )); then mv "$TOP/@factory" "$TOP/@omarchy-old-factory-123"; fi
  if (( boundary >= 2 )); then mv "$TOP/@omarchy-reset-factory" "$TOP/@factory"; fi
  if (( boundary >= 3 )); then mv "$TOP/@" "$TOP/@omarchy-old-123"; fi
  if (( boundary >= 4 )); then mv "$TOP/@omarchy-reset-next" "$TOP/@"; fi
  if (( boundary >= 4 )); then DEFAULT_UUID=$RESET_TXN_NEXT; fi
  reset_transaction_rollback "$TOP" "$STATE"
  [[ $(reset_uuid "$TOP/@") == "$RESET_TXN_ROOT" && $(reset_uuid "$TOP/@factory") == "$RESET_TXN_FACTORY" ]] || fail 'root+baseline rollback'
  [[ $(reset_uuid "$TOP/@omarchy-reset-next") == "$RESET_TXN_NEXT" && $(reset_uuid "$TOP/@omarchy-reset-factory") == "$RESET_TXN_CLEAN" ]] || fail 'known stage retained'
  [[ $(cat "$STATE/boot-verdict") == restored && $(cat "$STATE/phase") == rolled-back ]] || fail 'boot restored in same transaction'
  [[ $DEFAULT_UUID == "$RESET_TXN_ROOT" ]] || fail 'default root restored in same transaction'
  pass "root/baseline/boot reconciliation after $boundary exchange renames"
done
new_fixture retained-default
retained_uuid=77777777-7777-7777-7777-777777777777
fixture_volume "$TOP/@old-retained" "$retained_uuid"
RESET_TXN_DEFAULT=$retained_uuid RESET_TXN_DEFAULT_PATH=@old-retained
reset_transaction_record "$STATE"
mv "$TOP/@factory" "$TOP/@omarchy-old-factory-123"
mv "$TOP/@omarchy-reset-factory" "$TOP/@factory"
mv "$TOP/@" "$TOP/@omarchy-old-123"
mv "$TOP/@omarchy-reset-next" "$TOP/@"
DEFAULT_UUID=$RESET_TXN_NEXT
reset_transaction_rollback "$TOP" "$STATE"
[[ $DEFAULT_UUID == "$retained_uuid" && $(reset_uuid "$TOP/@old-retained") == "$retained_uuid" ]] || fail 'retained default rollback binding'
pass 'rollback restores an explicitly recorded retained default subvolume'
new_fixture collision
mv "$TOP/@" "$TOP/@omarchy-old-123"
fixture_volume "$TOP/@" 66666666-6666-6666-6666-666666666666
if reset_transaction_rollback "$TOP" "$STATE"; then fail 'unexpected current root'; fi
[[ $(reset_uuid "$TOP/@") == 66666666-6666-6666-6666-666666666666 && -d $TOP/@omarchy-old-123 ]] || fail 'unexpected root preserved'
pass 'unknown root collision fails without guessing'
new_fixture cancel
rm -r "${STATE:?}/boot"
RESET_TXN_NEXT=- RESET_TXN_CLEAN=-
reset_transaction_record "$STATE"
expected="$RESET_TXN_FS $RESET_TXN_STAMP $RESET_TXN_ROOT $RESET_TXN_FACTORY - -"
expected="$expected $RESET_TXN_DEFAULT"
expected="$expected $RESET_TXN_DEFAULT_PATH"
echo inventory >"$STATE/inventory"
reset_cancel_journal "$STATE" "$expected"
[[ ! -e $STATE ]] || fail 'cancel strands journal'
mkdir -m 700 "$STATE"
reset_transaction_record "$STATE"
reset_cancel_journal "$STATE" "$expected"
pass 'cancel then repeat pre-confirmation journal is retryable'
