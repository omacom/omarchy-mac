#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/install/helpers/factory-reset.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
python3 - "$ROOT/bin/omarchy-system-factory-reset" "$test_tmp/functions" <<'PY'
import pathlib,re,sys
text=pathlib.Path(sys.argv[1]).read_text()
functions=[]
for name in ['cleanup','prepare_reset_inventory']:
 match=re.search(r'^'+name+r'\(\) \{\n.*?^\}',text,re.M|re.S)
 assert match,name
 functions.append(match.group())
main=text[text.index('main() {'):]
assert main.index('prepare_reset_inventory')<main.index('confirm_reset')<main.index('stage_full_reset')
stage=text[text.index('stage_full_reset() {'):text.index('main() {')]
assert 'backend_quiesce' not in stage
pathlib.Path(sys.argv[2]).write_text('\n'.join(functions)+'\n')
PY
source "$test_tmp/functions"
OMARCHY_PATH="$test_tmp/source"
mkdir -p "$OMARCHY_PATH/bin"
cat >"$OMARCHY_PATH/bin/omarchy-mac-snapper-backend" <<'SHIM'
backend_quiesce() {
  echo snapper-quiesce >>"$EVENTS"
  writer_active=0
  [[ ${QUIESCE_FAIL:-0} == 0 ]]
}
backend_resume_services() {
  echo snapper-resume >>"$EVENTS"
  [[ ${RESUME_FAIL:-0} == 0 ]] || return 1
  writer_active=1
  rm "$BACKEND_SERVICE_RECEIPT"
}
SHIM
stat() { if [[ $* == '-c %u '* ]]; then echo 0; else command stat "$@"; fi; }
mountpoint() { return 0; }
umount() { :; }
fail() { echo "$*" >&2; exit 1; }
reset_limine_quiesce() {
 echo limine-quiesce >>"$EVENTS"
 printf '%s\n' 'mask limine-snapper-sync.path' 'path limine-snapper-sync.path' >"$RESET_STATE/limine-services"
 chmod 600 "$RESET_STATE/limine-services"
}
systemctl() { echo "limine-$*" >>"$EVENTS"; [[ ${LIMINE_RESUME_FAIL:-0} == 0 ]]; }
reset_inventory_build() {
 echo inventory-build >>"$EVENTS"
 echo captured >"$3"
 # A managed writer can add a descendant between capture and verification.
 (( !writer_active )) || echo appeared >>"$test_tmp/history"
}
reset_inventory_verify_sources() {
 echo inventory-verify >>"$EVENTS"
 [[ ! -s $test_tmp/history ]]
}
setup_case() {
 TOP_MNT="$test_tmp/$1" RESET_STATE="$test_tmp/$1/state" EVENTS="$test_tmp/$1-events"
 mkdir -p "$RESET_STATE"
 chmod 700 "$RESET_STATE"
 RESET_TXN_FS=f RESET_TXN_STAMP=s RESET_TXN_ROOT=r RESET_TXN_FACTORY=b RESET_TXN_DEFAULT=r RESET_TXN_DEFAULT_PATH=@
 printf '%s\n' 'f s r b - - r @' >"$RESET_STATE/identities"
 chmod 600 "$RESET_STATE/identities"
 : >"$EVENTS"; : >"$test_tmp/history"
 # shellcheck disable=SC2034 # read by the extracted command functions
 swap_done=0 reset_started=0 reset_journal_created=1 reset_services_started=0 writer_active=1
}
setup_case unpaused
reset_inventory_build "$TOP_MNT" s "$RESET_STATE/inventory" || true
if reset_inventory_verify_sources "$TOP_MNT" "$RESET_STATE/inventory"; then fail 'modeled writer must invalidate unpaused inventory'; fi
setup_case cancel
prepare_reset_inventory
[[ $(cat "$EVENTS") == $'snapper-quiesce\nlimine-quiesce\ninventory-build\ninventory-verify' ]] || fail 'maintenance must precede capture and remain active'
cleanup
[[ ! -e $RESET_STATE && $writer_active == 1 ]] || fail 'cancel must resume services before removing its journal'
pass 'managed writer is paused before inventory, and cancellation restores services and removes only the owned journal'

if (
  setup_case failed-quiesce
  trap cleanup EXIT
  export QUIESCE_FAIL=1
  prepare_reset_inventory
); then fail 'partial quiesce must fail'; fi
[[ ! -e $test_tmp/failed-quiesce/state ]] || fail 'partial maintenance failure must remove its journal after restoring services'
grep -qx snapper-resume "$test_tmp/failed-quiesce-events" || fail 'partial failure did not restore services'
pass 'partial pre-confirm maintenance failure restores services and leaves reset retryable'

setup_case failed-resume
prepare_reset_inventory
export RESUME_FAIL=1
if cleanup; then fail 'failed service restoration must fail cleanup'; fi
unset RESUME_FAIL
[[ -f $RESET_STATE/identities && -f $RESET_STATE/inventory && -f $RESET_STATE/services ]] || fail 'failed restoration must retain identities, inventory and receipt'
pass 'failed restoration preserves the pre-confirm journal and service receipt for inspection'

setup_case failed-limine-resume
prepare_reset_inventory
LIMINE_RESUME_FAIL=1
if cleanup; then fail 'failed Limine restoration must fail cleanup'; fi
unset LIMINE_RESUME_FAIL
[[ -f $RESET_STATE/identities && -f $RESET_STATE/limine-services ]] || fail 'failed Limine restoration must preserve its validated receipt and identities'
pass 'real Limine receipt is removed only after successful restoration and retained on failure'
