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
[[ ${FAIL_AT:-} != timer ]] || exit 23
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
  cmp "$ROOT/default/snapper/root" "$FIXTURE/root"
  [[ $(cat "$FIXTURE/registry") == $'home,/home\nroot,/' ]] || fail 'registration preserves home'
  echo 'NUMBER_LIMIT="42"' >>"$FIXTURE/root"
  cp "$FIXTURE/root" "$FIXTURE/expected-root"
  cp "$FIXTURE/registry" "$FIXTURE/expected-registry"
  run_leaf "$mode"
  cmp "$FIXTURE/expected-root" "$FIXTURE/root"
  cmp "$FIXTURE/expected-registry" "$FIXTURE/registry"
  [[ $(cat "$FIXTURE/home") == 'custom home retention' ]] || fail 'home unchanged'
  [[ $(grep -c 'create-config' "$TEST_LOG") == 1 ]] || fail 'retry never recreates root'
  ! grep -E 'timeline|delete|limine' "$TEST_LOG" || fail 'preserve global timeline and snapshots'

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
  new_fixture "ext4-$mode"
  TEST_FILESYSTEM=ext2/ext3 run_leaf "$mode"
  [[ ! -e $TEST_LOG ]] || fail 'non-btrfs skips before dependencies and mutations'
  pass "$mode preserves custom multi-config state, rejects partial state and propagates failures"
done

new_fixture missing-template
if OMARCHY_SNAPPER_TEMPLATE="$FIXTURE/absent" run_leaf direct; then fail 'missing template fails'; fi
! grep -E 'create-config|systemctl' "$TEST_LOG" || fail 'template checked before mutations'
pass 'missing template fails before changing services or backend'
