#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"

cat >"$test_tmp/bin/stat" <<'STUB'
#!/bin/bash
[[ $* == '-f -c %T /' ]] || exit 2
if [[ ${TEST_FILESYSTEM:-btrfs} == error ]]; then
  echo 'stat: cannot inspect root filesystem' >&2
  exit 1
fi
printf '%s\n' "${TEST_FILESYSTEM:-btrfs}"
STUB
cat >"$test_tmp/bin/snapper" <<'STUB'
#!/bin/bash
printf 'snapper %s\n' "$*" >>"$TEST_LOG"
[[ $* == '--no-dbus -c root create-config /' ]] || exit 99
if (( ${TEST_SNAPPER_STATUS:-0} )); then
  echo 'snapper: fixture backend failure' >&2
  exit "$TEST_SNAPPER_STATUS"
fi
printf 'SUBVOLUME="/"\nFSTYPE="btrfs"\n' >"$OMARCHY_SNAPPER_CONFIG_PATH"
STUB
cat >"$test_tmp/bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
[[ $* != 'cat limine-snapper-sync.service' ]]
STUB
chmod +x "$test_tmp/bin/"*

run_configure() {
  PATH="$test_tmp/bin:$PATH" TEST_LOG="$test_tmp/$1.calls" \
    OMARCHY_PATH="$ROOT" \
    OMARCHY_SNAPPER_CONFIG_PATH="$test_tmp/$1/root" \
    OMARCHY_SNAPPER_CONF_PATH="$test_tmp/$1/conf" \
    bash -euo pipefail "$ROOT/install/config/snapper.sh"
}

run_configure success >"$test_tmp/success.output" 2>&1
cmp "$ROOT/default/snapper/root" "$test_tmp/success/root"
grep -Fx 'snapper --no-dbus -c root create-config /' "$test_tmp/success.calls" >/dev/null
grep -Fx 'systemctl enable --now snapper-cleanup.timer' "$test_tmp/success.calls" >/dev/null
run_configure success >>"$test_tmp/success.output" 2>&1
[[ $(grep -c '^snapper ' "$test_tmp/success.calls") == 1 ]] || fail 'existing root config is not recreated'
pass 'fresh btrfs root uses offline Snapper setup and normalizes policy idempotently'

for status in 1 127; do
  result=0
  TEST_SNAPPER_STATUS=$status run_configure "failure-$status" >"$test_tmp/failure.output" 2>&1 || result=$?
  [[ $result == "$status" ]] || fail 'Snapper backend status propagates' "got $result, expected $status"
  grep -F 'snapper: fixture backend failure' "$test_tmp/failure.output" >/dev/null
  grep -F "Snapper root configuration failed on btrfs (exit $status)" "$test_tmp/failure.output" >/dev/null
  ! grep -F 'Skipping' "$test_tmp/failure.output" >/dev/null || fail 'btrfs failure is not called unsupported'
  [[ ! -e $test_tmp/failure-$status/root && ! -e $test_tmp/failure-$status/conf ]] || fail 'failed setup does not install policy'
  ! grep -q '^systemctl ' "$test_tmp/failure-$status.calls" || fail 'failed setup does not enable timers'
done
pass 'missing or broken Snapper fails btrfs setup with its original diagnostic and status'

TEST_FILESYSTEM=ext2/ext3 run_configure ext4 >"$test_tmp/ext4.output" 2>&1
grep -F 'ext2/ext3, not btrfs' "$test_tmp/ext4.output" >/dev/null
[[ ! -e $test_tmp/ext4.calls && ! -e $test_tmp/ext4/root ]] || fail 'ext4 is skipped before invoking Snapper'
pass 'non-btrfs roots skip snapshot setup based on the actual filesystem'

if TEST_FILESYSTEM=error run_configure stat-error >"$test_tmp/stat-error.output" 2>&1; then
  fail 'filesystem inspection failure must not be treated as an unsupported root'
fi
grep -F 'cannot inspect root filesystem' "$test_tmp/stat-error.output" >/dev/null
pass 'filesystem inspection errors remain fatal and visible'
