#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"
cat >"$test_tmp/bin/stat" <<'STUB'
#!/bin/bash
[[ ${FAIL_AT:-} != stat ]] || exit 17
printf '%s\n' "${TEST_FILESYSTEM:-btrfs}"
STUB
cat >"$test_tmp/bin/snapper" <<'STUB'
#!/bin/bash
printf 'snapper %s\n' "$*" >>"$TEST_LOG"
case "$*" in
  '--no-dbus --csvout list-configs --columns config,subvolume')
    [[ ${FAIL_AT:-} != probe ]] || exit 18
    printf 'config,subvolume\n'
    cat "$FIXTURE/registry" ;;
  '--no-dbus -c root create-config --template omarchy /')
    [[ ${FAIL_AT:-} != create ]] || exit 19
    cp "$ROOT/default/snapper/root" "$FIXTURE/root" || exit
    [[ ${FAIL_AT:-} != partial ]] || exit 20
    mkdir "$FIXTURE/snapshots" || exit
    echo 'root,/' >>"$FIXTURE/registry" ;;
  '--no-dbus --csvout -c root get-config --columns key,value')
    [[ ${FAIL_AT:-} != settings ]] || exit 24
    printf 'key,value\nSUBVOLUME,/\nFSTYPE,btrfs\n' ;;
  '--no-dbus -c root list')
    [[ ${FAIL_AT:-} != list ]] || exit 21 ;;
  *) exit 99 ;;
esac
STUB
cat >"$test_tmp/bin/btrfs" <<'STUB'
#!/bin/bash
printf 'btrfs %s\n' "$*" >>"$TEST_LOG"
[[ ${FAIL_AT:-} != backend && -d $FIXTURE/snapshots ]] || exit 22
STUB
cat >"$test_tmp/bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
case "$*" in
  'enable --now snapper-cleanup.timer')
    [[ ${FAIL_AT:-} != timer ]] || exit 23
    touch "$FIXTURE/cleanup-active" ;;
  'cat limine-snapper-sync.service')
    [[ ${TEST_LIMINE_AVAILABLE:-0} == "1" ]] ;;
  'enable --now limine-snapper-sync.service')
    [[ ${TEST_LIMINE_AVAILABLE:-0} == "1" ]] || exit 99
    [[ ${FAIL_AT:-} != limine ]] || exit 26
    touch "$FIXTURE/limine-active" ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$test_tmp/bin/"*
export PATH="$test_tmp/bin:$PATH" OMARCHY_PATH="$ROOT" OMARCHY_SNAPPER_TEMPLATE="$ROOT/default/snapper/root"
new_fixture() {
  export FIXTURE="$test_tmp/$1" TEST_LOG="$test_tmp/$1/calls"
  mkdir -p "$FIXTURE"
  export OMARCHY_SNAPPER_CONFIG_PATH="$FIXTURE/root" OMARCHY_SNAPPER_SNAPSHOTS_PATH="$FIXTURE/snapshots"
  printf 'home,/home\n' >"$FIXTURE/registry"
  printf 'custom home retention\n' >"$FIXTURE/home"
}
run_leaf() {
  case "$1" in
    direct) bash -euo pipefail "$ROOT/install/config/snapper.sh" ;;
    source) bash -euo pipefail -c 'source "$ROOT/install/config/snapper.sh"' ;;
    conditional) bash -euo pipefail -c 'if source "$ROOT/install/config/snapper.sh"; then exit 0; else exit $?; fi' ;;
  esac
}
for mode in direct source conditional; do
  new_fixture "success-$mode"
  run_leaf "$mode"
  [[ -f $FIXTURE/cleanup-active ]] || fail 'fresh root activates cleanup'
  cmp "$ROOT/default/snapper/root" "$FIXTURE/root"
  [[ $(cat "$FIXTURE/registry") == $'home,/home\nroot,/' ]] || fail 'registration preserves home'
  echo 'NUMBER_LIMIT="42"' >>"$FIXTURE/root"
  cp "$FIXTURE/root" "$FIXTURE/expected-root"
  cp "$FIXTURE/registry" "$FIXTURE/expected-registry"
  rm "$FIXTURE/cleanup-active"
  status=0
  FAIL_AT=timer run_leaf "$mode" >"$FIXTURE/output" 2>&1 || status=$?
  (( status == 23 )) || fail 'existing backend propagates cleanup activation failure'
  [[ ! -e $FIXTURE/cleanup-active ]] || fail 'failed activation does not claim active cleanup'
  run_leaf "$mode"
  [[ -f $FIXTURE/cleanup-active ]] || fail 'existing root repairs cleanup on retry'
  cmp "$FIXTURE/expected-root" "$FIXTURE/root"
  cmp "$FIXTURE/expected-registry" "$FIXTURE/registry"
  [[ $(cat "$FIXTURE/home") == 'custom home retention' ]] || fail 'home unchanged'
  [[ $(grep -c 'create-config' "$TEST_LOG") == 1 ]] || fail 'retry never recreates root'
  ! grep -E 'timeline|delete' "$TEST_LOG" || fail 'preserve global timeline and snapshots'
  ! grep -F 'enable --now limine' "$TEST_LOG" || fail 'absent optional Limine unit is not activated'

  for failure in stat probe create partial list backend timer settings; do
    new_fixture "$mode-$failure"
    status=0
    FAIL_AT="$failure" run_leaf "$mode" >"$FIXTURE/output" 2>&1 || status=$?
    (( status != 0 )) || fail "$mode propagates $failure"
    if [[ $failure == partial ]]; then
      cmp "$ROOT/default/snapper/root" "$FIXTURE/root"
      if run_leaf "$mode" >>"$FIXTURE/output" 2>&1; then fail 'partial create stays failed'; fi
      [[ $(grep -c 'create-config' "$TEST_LOG") == 1 ]] || fail 'partial create never retried destructively'
    fi
  done
  for partial in file backend unregistered mismatch alternate; do
    new_fixture "$mode-existing-$partial"
    case "$partial" in
      file) cp "$ROOT/default/snapper/root" "$FIXTURE/root"; echo 'root,/' >>"$FIXTURE/registry" ;;
      backend) mkdir "$FIXTURE/snapshots" ;;
      unregistered) cp "$ROOT/default/snapper/root" "$FIXTURE/root" ;;
      mismatch) echo 'root,/wrong' >>"$FIXTURE/registry" ;;
      alternate) echo 'system,/' >>"$FIXTURE/registry" ;;
    esac
    cp "$FIXTURE/registry" "$FIXTURE/expected-registry"
    if run_leaf "$mode" >"$FIXTURE/output" 2>&1; then fail "$partial must fail closed"; fi
    cmp "$FIXTURE/registry" "$FIXTURE/expected-registry"
    ! grep -E 'create-config|systemctl' "$TEST_LOG" || fail 'partial state has no mutations'
  done
  new_fixture "limine-$mode"
  TEST_LIMINE_AVAILABLE=1 run_leaf "$mode"
  [[ -f $FIXTURE/cleanup-active && -f $FIXTURE/limine-active ]] || fail 'fresh root activates available Limine sync'
  cp "$FIXTURE/root" "$FIXTURE/expected-root"
  cp "$FIXTURE/registry" "$FIXTURE/expected-registry"
  rm "$FIXTURE/limine-active"
  status=0
  TEST_LIMINE_AVAILABLE=1 FAIL_AT=limine run_leaf "$mode" >"$FIXTURE/output" 2>&1 || status=$?
  (( status == 26 )) || fail 'existing root propagates optional service failure'
  [[ ! -e $FIXTURE/limine-active ]] || fail 'failed optional service remains inactive'
  TEST_LIMINE_AVAILABLE=1 run_leaf "$mode"
  [[ -f $FIXTURE/limine-active ]] || fail 'existing root repairs optional service on retry'
  cmp "$FIXTURE/root" "$FIXTURE/expected-root"
  cmp "$FIXTURE/registry" "$FIXTURE/expected-registry"
  [[ $(grep -c create-config "$TEST_LOG") == 1 ]] || fail 'service repair does not recreate backend'
  ! grep -E 'timeline|delete' "$TEST_LOG" || fail 'optional service repair preserves timeline and snapshots'
  new_fixture "ext4-$mode"
  TEST_FILESYSTEM=ext2/ext3 run_leaf "$mode"
  [[ ! -e $TEST_LOG ]] || fail 'non-btrfs skips before dependencies and mutations'
  pass "$mode preserves custom multi-config state, rejects partial state and propagates failures"
done

new_fixture missing-template
if OMARCHY_SNAPPER_TEMPLATE="$FIXTURE/absent" run_leaf direct; then fail 'missing template fails'; fi
! grep -E 'create-config|systemctl' "$TEST_LOG" || fail 'template checked before mutations'
pass 'missing template fails before changing services or backend'

migration=$(rg -l '^echo "Repair missing Snapper root setup after the required dependency update"' "$ROOT/migrations")
[[ -n $migration ]] || fail 'new repair migration exists'
mkdir -p "$test_tmp/repo/migrations" "$test_tmp/repo/install/config"
cp "$migration" "$test_tmp/repo/migrations/"
cp "$ROOT/install/config/snapper.sh" "$test_tmp/repo/install/config/"
printf 'exit 99\n' >"$test_tmp/repo/migrations/1781984677.sh"
printf 'echo later\n' >"$test_tmp/repo/migrations/9999999999.sh"
cat >"$test_tmp/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
[[ ${FAIL_AT:-} != sudo ]] || exit 25
"$@"
STUB
chmod +x "$test_tmp/bin/sudo"
run_migrate() {
  OMARCHY_PATH="$test_tmp/repo" OMARCHY_MIGRATION_STATE="$FIXTURE/state" bash "$ROOT/bin/omarchy-migrate"
}
seed_old_marker() {
  mkdir -p "$FIXTURE/state"
  touch "$FIXTURE/state/1781984677.sh"
}
new_fixture migration
seed_old_marker
run_migrate >"$FIXTURE/output" 2>&1
[[ -f $FIXTURE/state/$(basename "$migration") && -f $FIXTURE/state/9999999999.sh ]] || fail 'new migration completes despite old marker'
run_migrate >>"$FIXTURE/output" 2>&1
rm -r "$FIXTURE/state"
seed_old_marker
run_migrate >>"$FIXTURE/output" 2>&1
[[ $(grep -c 'create-config' "$TEST_LOG") == 1 ]] || fail 'retry and second user never recreate backend'
pass 'new migration repairs already-marked released installs and second user is idempotent'

for failure in stat probe create partial list backend timer settings limine sudo; do
  # Root execution deliberately has no sudo call.
  if [[ $failure == sudo ]] && (( EUID == 0 )); then continue; fi
  new_fixture "migration-$failure"
  seed_old_marker
  if TEST_LIMINE_AVAILABLE=1 FAIL_AT="$failure" run_migrate >"$FIXTURE/output" 2>&1; then fail "migration must propagate $failure"; fi
  [[ ! -e $FIXTURE/state/$(basename "$migration") && ! -e $FIXTURE/state/9999999999.sh ]] || fail "$failure leaves migration and later markers absent"
done
pass 'migration probe, privilege and mutation failures stop the queue without markers'

# An isolated PATH proves unsupported roots skip even a missing dependency and
# that btrfs does not claim success until the package update provides Snapper.
mkdir "$test_tmp/no-snapper"
ln -s "$test_tmp/bin/stat" "$test_tmp/no-snapper/stat"
new_fixture dependency
for mode in direct source conditional; do
  case "$mode" in
    direct) invocation='"$MIGRATION"' ;;
    source) invocation='source "$MIGRATION"' ;;
    conditional) invocation='if source "$MIGRATION"; then exit 0; else exit $?; fi' ;;
  esac
  if [[ $mode == direct ]]; then
    status=0
    PATH="$test_tmp/no-snapper" /bin/bash -euo pipefail "$migration" >"$FIXTURE/output" 2>&1 || status=$?
  else
    status=0
    PATH="$test_tmp/no-snapper" MIGRATION="$migration" /bin/bash -euo pipefail -c "$invocation" >"$FIXTURE/output" 2>&1 || status=$?
  fi
  (( status == 127 )) || fail 'missing Snapper fails visibly on btrfs'
  PATH="$test_tmp/no-snapper" TEST_FILESYSTEM=ext2/ext3 /bin/bash -euo pipefail "$migration"
done
[[ ! -e $TEST_LOG ]] || fail 'dependency gates precede privilege'
pass 'missing dependency fails btrfs repair; non-btrfs skips before privilege in all invocation contexts'
