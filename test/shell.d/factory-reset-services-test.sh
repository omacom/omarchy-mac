#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/install/helpers/factory-reset.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stat() { if [[ $* == '-c %u '* ]]; then echo 0; else command stat "$@"; fi; }
sync() { :; }
sleep() { :; }
EVENTS="$test_tmp/events"
: >"$EVENTS"
SERVICE_MASK=masked PATH_MASK=enabled PATH_ACTIVE=active ABSENT=0
systemctl() {
  local command=$1 unit=${2:-}
  case "$command $unit ${3:-}" in
    'show '*\ --property=LoadState) if (( ABSENT )); then echo not-found; else echo loaded; fi ;;
    'show limine-snapper-sync.service --property=ActiveState') echo inactive ;;
    'show limine-snapper-sync.path --property=ActiveState') echo "$PATH_ACTIVE" ;;
    'is-enabled limine-snapper-sync.service '*) echo "$SERVICE_MASK" ;;
    'is-enabled limine-snapper-sync.path '*) echo "$PATH_MASK" ;;
    *) printf '%s\n' "$*" >>"$EVENTS" ;;
  esac
}
mkdir -m 700 "$test_tmp/state"
reset_limine_quiesce "$test_tmp/state"
reset_limine_resume "$test_tmp/state"
grep -qx 'stop limine-snapper-sync.path' "$EVENTS" || fail 'active path stopped'
grep -qx 'unmask --runtime limine-snapper-sync.path' "$EVENTS" || fail 'own path mask restored'
grep -qx 'start limine-snapper-sync.path' "$EVENTS" || fail 'prior active path restored'
if grep -q 'unmask.*limine-snapper-sync.service' "$EVENTS"; then fail 'administrator service mask removed'; fi
if grep -q 'stop.*limine-snapper-sync.service' "$EVENTS"; then fail 'writer service interrupted'; fi
pass 'ordinary rollback restores only owned Limine path state and preserves admin service mask'
mkdir -m 700 "$test_tmp/absent"
ABSENT=1
cp "$EVENTS" "$test_tmp/expected"
reset_limine_quiesce "$test_tmp/absent"
reset_limine_resume "$test_tmp/absent"
cmp "$EVENTS" "$test_tmp/expected" || fail 'absent backend mutated service state'
pass 'GRUB installation with absent Limine units needs no service mutation'
mkdir -m 700 "$test_tmp/masked-active"
ABSENT=0 PATH_MASK=masked
if reset_limine_quiesce "$test_tmp/masked-active"; then fail 'masked active custom path'; fi
cmp "$EVENTS" "$test_tmp/expected" || fail 'custom active mask was changed'
pass 'masked-but-active administrator path is preserved on refusal'
