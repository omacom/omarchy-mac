#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/install/helpers/factory-reset.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stat() { if [[ $* == '-c %u '* ]]; then echo 0; else command stat "$@"; fi; }
sync() { :; }
fixture_volume() { mkdir -p "$1"; printf '%s\n' "$2" >"$1/.uuid"; }
reset_uuid() { [[ ! -L $1 && -f $1/.uuid ]] && cat "$1/.uuid"; }
reset_default_uuid() { printf '%s\n' "${DEFAULT_UUID:--}"; }
reset_empty_volume() { [[ -z $(find "$1" -mindepth 1 ! -name .uuid -print -quit) ]]; }
reset_nested_paths() {
  local path
  # Match real list -o: stop at each directly contained subvolume instead of
  # flattening all descendants (which hid the missing recursive walk).
  while IFS= read -r path; do printf '%s\n' "${path#"$TOP/"}"; done < <(
    find "$1" -mindepth 1 -type d -exec test -f '{}/.uuid' \; -print -prune | sort
  )
}

findmnt() { printf '%s\n' "${MOUNTS:-/ /test none}"; }
btrfs() {
  case "$1 $2" in
    'subvolume delete') echo "$3" >>"$DELETIONS"; [[ ${FAIL_DELETE:-} != "$3" ]] || return 71; rm "$3/.uuid"; rmdir "$3" ;;
    'subvolume create') fixture_volume "$3" aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa ;;
    *) return 99 ;;
  esac
}
new_fixture() {
  TOP="$test_tmp/$1/top"; mkdir -p "$TOP"
  MANIFEST="$test_tmp/$1/inventory" STATE="$test_tmp/$1/state" DELETIONS="$test_tmp/$1/deletions"
  : >"$DELETIONS"; MOUNTS="" FAIL_DELETE="" DEFAULT_UUID=-
  fixture_volume "$TOP/@" 11111111-1111-1111-1111-111111111111
  fixture_volume "$TOP/@factory" 22222222-2222-2222-2222-222222222222
  fixture_volume "$TOP/@old-1" 33333333-3333-3333-3333-333333333333
  fixture_volume "$TOP/@old-1/.snapshots" 44444444-4444-4444-4444-444444444444
  fixture_volume "$TOP/@fresh" 55555555-5555-5555-5555-555555555555
  fixture_volume "$TOP/@home" 66666666-6666-6666-6666-666666666666
  fixture_volume "$TOP/@admin" 77777777-7777-7777-7777-777777777777
  reset_inventory_build "$TOP" 123 "$MANIFEST"
}
move_roots() { mv "$TOP/@" "$TOP/@omarchy-old-123"; mv "$TOP/@factory" "$TOP/@omarchy-old-factory-123"; }
FS_UUID=99999999-9999-9999-9999-999999999999
new_fixture inventory
[[ $(wc -l <"$MANIFEST") == 6 ]] || fail 'every selected root and nested history recorded'
reset_inventory_verify_sources "$TOP" "$MANIFEST"
reset_inventory_display "$MANIFEST" >"$test_tmp/display"
grep -q 'Legacy names are not ownership proof' "$test_tmp/display" || fail 'legacy ownership caveat'
! grep -q @admin "$MANIFEST" || fail 'admin not inferred'
fixture_volume "$TOP/@old-1/new-child" 88888888-8888-8888-8888-888888888888
if reset_inventory_verify_sources "$TOP" "$MANIFEST"; then fail 'new descendant must invalidate confirmation'; fi
pass 'explicit full descendant inventory and changed-set refusal'
new_fixture collision
fixture_volume "$TOP/@omarchy-old-123" 88888888-8888-8888-8888-888888888888
if reset_inventory_verify_sources "$TOP" "$MANIFEST"; then fail 'root destination collision'; fi
pass 'preflight root collision'
new_fixture mounted
move_roots
MOUNTS="/somewhere $FS_UUID /@old-1/.snapshots"
if reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"; then fail 'mounted nested history'; fi
[[ ! -s $DELETIONS ]] || fail 'whole inventory preflight before any deletion'
pass 'mounted descendant prevents all cleanup mutation'
new_fixture default
move_roots
DEFAULT_UUID=33333333-3333-3333-3333-333333333333
if reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"; then fail 'default subvolume deletion'; fi
[[ ! -s $DELETIONS ]] || fail 'default subvolume refusal must precede deletion'
pass 'cleanup refuses a selected default subvolume before deleting anything'
new_fixture unexpected
move_roots
fixture_volume "$TOP/@old-1/new-child" 88888888-8888-8888-8888-888888888888
if reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"; then fail 'unknown child'; fi
[[ ! -s $DELETIONS ]] || fail 'unknown child preflight before deletion'
pass 'unlisted nested subvolume preserved'
new_fixture identity
move_roots
echo 88888888-8888-8888-8888-888888888888 >"$TOP/@fresh/.uuid"
if reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"; then fail 'changed UUID'; fi
[[ ! -s $DELETIONS ]] || fail 'changed identity detected before deletion'
pass 'changed identity loses authorization'
new_fixture retry
move_roots
FAIL_DELETE="$TOP/@fresh"
if reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"; then fail 'injected cleanup failure'; fi
FAIL_DELETE=
reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"
reset_recreate_clean_subvolume "$TOP" @home "$STATE"
# Emulate an ordinary later failure after home recreation, then actual retry.
reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"
reset_recreate_clean_subvolume "$TOP" @home "$STATE"
[[ $(reset_uuid "$TOP/@home") == aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa && -d $TOP/@admin ]] || fail 'replacement/admin preserved'
[[ ! -e $TOP/@fresh && ! -e $TOP/@old-1 ]] || fail 'all authorized history erased'
pass 'partial deletion and post-home recreation retry preserve exact new identity'
echo bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb >"$TOP/@home/.uuid"
if reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"; then fail 'arbitrary replacement'; fi
pass 'replacement receipt does not authorize different subvolume'
new_fixture state
move_roots
mkdir -m 755 "$STATE"
if reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"; then fail 'permissive state'; fi
[[ ! -s $DELETIONS ]] || fail 'state failure preserves roots'
pass 'state permissions fail closed'
new_fixture binding
move_roots
reset_state_bind "$MANIFEST" "$STATE" "$FS_UUID"
if reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" 88888888-8888-8888-8888-888888888888; then fail 'filesystem changed'; fi
[[ ! -s $DELETIONS ]] || fail 'binding failure preserves roots'
pass 'filesystem and manifest state binding'

new_fixture receipt_write
move_roots
reset_cleanup_inventory "$TOP" "$MANIFEST" "$STATE" "$FS_UUID"
eval "$(declare -f reset_state_write | sed '1s/reset_state_write/real_state_write/')"
reset_state_write() { [[ $1 != "$STATE/replacement-home" ]] || return 72; real_state_write "$@"; }
if reset_recreate_clean_subvolume "$TOP" @home "$STATE"; then fail 'receipt write failure'; fi
[[ ! -e $TOP/@home && ! -e $TOP/@omarchy-reset-home ]] || fail 'own empty unrecorded temporary removed'
reset_state_write() { real_state_write "$@"; }
reset_recreate_clean_subvolume "$TOP" @home "$STATE"
pass 'failed replacement receipt cleans only own empty temporary and permits retry'

new_fixture deep
fixture_volume "$TOP/@/.snapshots" 88888888-8888-8888-8888-888888888888
fixture_volume "$TOP/@/.snapshots/1/snapshot" 99999999-9999-9999-9999-999999999999
fixture_volume "$TOP/@/.snapshots/1/snapshot/deeper" aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
MANIFEST="$test_tmp/deep/complete-inventory"
reset_inventory_build "$TOP" 123 "$MANIFEST"
[[ $(wc -l <"$MANIFEST") == 9 ]] || fail 'every depth must be captured exactly once'
grep -qx $'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\t@/.snapshots/1/snapshot/deeper\t@omarchy-old-123/.snapshots/1/snapshot/deeper\tnested-current-root' "$MANIFEST" || fail 'deep UUID and destination mapping'
reset_inventory_verify_sources "$TOP" "$MANIFEST"
pass 'direct-child enumeration recursively captures three nested levels with exact destination identities'
eval "$(declare -f reset_nested_paths | sed '1s/reset_nested_paths/direct_nested_paths/')"
reset_nested_paths() {
 direct_nested_paths "$1"
 if [[ $1 == "$TOP/@" ]]; then
   printf '%s\n' '@/.snapshots/1/snapshot' '@/.snapshots/1/snapshot/deeper'
 fi
}
reset_inventory_build "$TOP" 123 "$test_tmp/deep/recursive-list-inventory"
cmp "$MANIFEST" "$test_tmp/deep/recursive-list-inventory" || fail 'recursive list variants must record each path once'
reset_inventory_verify_sources "$TOP" "$test_tmp/deep/recursive-list-inventory"
pass 'repeated paths from recursive listing variants are inventoried exactly once'
fixture_volume "$TOP/@/.snapshots/duplicate" aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
if reset_inventory_build "$TOP" 123 "$test_tmp/deep/duplicate-inventory"; then fail 'duplicate descendant UUID must refuse'; fi
pass 'recursive inventory refuses duplicate identities without authorizing cleanup'
