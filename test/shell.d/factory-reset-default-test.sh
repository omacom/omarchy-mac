#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/install/helpers/factory-reset.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
top="$test_tmp/top"
mkdir -p "$top/@old" "$top/@next"
printf '%s\n' 11111111-1111-1111-1111-111111111111 >"$top/@old/.uuid"
printf '%s\n' 22222222-2222-2222-2222-222222222222 >"$top/@next/.uuid"
reset_uuid() { [[ -f $1/.uuid && ! -L $1 ]] && cat "$1/.uuid"; }
DEFAULT_PATH=@old
btrfs() {
  case "$1 $2" in
    'subvolume get-default')
      if [[ $DEFAULT_PATH == FS_TREE ]]; then printf '%s\n' 'ID 5 (FS_TREE)';
      else printf 'ID 257 gen 42 top level 5 path %s\n' "$DEFAULT_PATH"; fi ;;
    'subvolume set-default')
      if [[ $3 == 5 && $4 == "$top" ]]; then DEFAULT_PATH=FS_TREE;
      elif [[ $3 == "$top/"* ]]; then DEFAULT_PATH=${3#"$top/"};
      else return 1; fi ;;
    *) return 1 ;;
  esac
}
[[ $(reset_default_uuid "$top") == 11111111-1111-1111-1111-111111111111 ]] || fail 'default UUID parsing'
[[ $(reset_default_identity "$top") == $'11111111-1111-1111-1111-111111111111\t@old' ]] || fail 'default identity and path binding'
manifest="$test_tmp/inventory"
printf '%s\t%s\t%s\t%s\n' 11111111-1111-1111-1111-111111111111 @old @old retained >"$manifest"
reset_default_in_inventory "$manifest" 11111111-1111-1111-1111-111111111111 @old
if reset_default_in_inventory "$manifest" 22222222-2222-2222-2222-222222222222 @next; then fail 'uninventoried default accepted'; fi
reset_default_set "$top" 22222222-2222-2222-2222-222222222222 "$top/@next"
[[ $DEFAULT_PATH == @next && $(reset_default_uuid "$top") == 22222222-2222-2222-2222-222222222222 ]] || fail 'default handoff verification'
reset_default_set_top "$top"
[[ $DEFAULT_PATH == FS_TREE && $(reset_default_uuid "$top") == - ]] || fail 'top-level default restoration'
reset_default_restore "$top" 11111111-1111-1111-1111-111111111111 @old
[[ $DEFAULT_PATH == @old ]] || fail 'recorded retained default restoration'
DEFAULT_PATH=../unsafe
if reset_default_uuid "$top"; then fail 'unsafe default path accepted'; fi
pass 'default identity, handoff, restoration and unsafe-path refusal'
