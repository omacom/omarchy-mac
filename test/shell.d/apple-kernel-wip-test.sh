#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

kernel_wip="$ROOT/bin/omarchy-mac-kernel-wip"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
boot="$test_tmp/esp/m1n1/boot.bin"
mkdir -p "$stub_bin" "$(dirname "$boot")"
printf 'released-dtbs\n' >"$boot"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
if [[ ${TEST_FAIL_BOOT_COPY:-0} == "1" && $1 == "cp" ]]; then
  exit 1
fi
exec "$@"
SH
chmod +x "$stub_bin/sudo"

run_helper() {
  PATH="$stub_bin:$PATH" OMARCHY_M1N1_BOOT_BIN="$boot" bash -c '
    # shellcheck source=/dev/null
    source "$1"
    shift
    conditional_rollback() {
      if rollback_boot_bin; then
        return 0
      else
        return 1
      fi
    }
    "$@"
  ' bash "$kernel_wip" "$@"
}

[[ $(run_helper m1n1_boot_bin) == "$boot" ]] || fail "m1n1_boot_bin honours OMARCHY_M1N1_BOOT_BIN"
pass "m1n1_boot_bin honours OMARCHY_M1N1_BOOT_BIN"

run_helper snapshot_boot_bin || fail "snapshot_boot_bin copies the current image"
[[ -f ${boot}.omarchy-pre-wip ]] || fail "snapshot_boot_bin writes boot.bin.omarchy-pre-wip"
cmp -s "$boot" "${boot}.omarchy-pre-wip" || fail "the snapshot matches the released image"
pass "snapshot_boot_bin keeps the released boot.bin"

printf 'wip-dtbs\n' >"$boot"
run_helper snapshot_boot_bin || fail "a second snapshot is a no-op"
cmp -s "${boot}.omarchy-pre-wip" <(printf 'released-dtbs\n') ||
  fail "a later WIP image does not replace the released snapshot"
pass "a second snapshot does not replace the released image"

run_helper rollback_boot_bin || fail "rollback_boot_bin restores the snapshot"
cmp -s "$boot" <(printf 'released-dtbs\n') || fail "rollback restores the pre-WIP boot.bin"
pass "rollback_boot_bin restores boot.bin.omarchy-pre-wip"

printf 'wip-dtbs-again\n' >"$boot"
rm -f "${boot}.omarchy-pre-wip"
printf 'update-m1n1-old\n' >"${boot}.old"
run_helper rollback_boot_bin || fail "rollback falls back to boot.bin.old"
cmp -s "$boot" <(printf 'update-m1n1-old\n') || fail "rollback uses update-m1n1's boot.bin.old"
pass "rollback_boot_bin falls back to boot.bin.old"

printf 'wip-dtbs\n' >"$boot"
if TEST_FAIL_BOOT_COPY=1 run_helper conditional_rollback >"$test_tmp/rollback-log" 2>&1; then
  fail "rollback_boot_bin fails when copying the saved image fails"
fi
! grep -q 'Restored' "$test_tmp/rollback-log" || fail "failed rollback does not report success"
cmp -s "$boot" <(printf 'wip-dtbs\n') || fail "failed rollback leaves the boot image unchanged"
pass "rollback_boot_bin reports copy failures even in a conditional"

rm -f "${boot}.old"
! run_helper rollback_boot_bin || fail "rollback fails when no saved image exists"
pass "rollback_boot_bin fails closed without a saved image"

grep -q 'not a' "$kernel_wip" && grep -q 'safe fallback' "$kernel_wip" ||
  fail "the command warns that the released GRUB entry is not a safe fallback"
! grep -q 'linux-asahi entry is still there if the branch does not boot' "$kernel_wip" ||
  fail "the old GRUB-fallback log line is gone"
pass "the command does not promise the released kernel is a safe GRUB fallback"

# Exercise --remove with every system command stubbed. A failed rebuild must
# leave the pre-WIP image available for recovery, and must fail the command.
if (( EUID == 0 )); then
  pass "--remove runs as a regular user; skipping its entry point as root"
  exit 0
fi

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash
printf 'aarch64\n'
SH
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
if [[ $1 == "-R" ]]; then
  printf 'package-hook-dtbs\n' >"$OMARCHY_M1N1_BOOT_BIN"
fi
SH
cat >"$stub_bin/update-m1n1" <<'SH'
#!/bin/bash
exit "${TEST_REBUILD_STATUS:-0}"
SH
cat >"$stub_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$stub_bin"/*

printf 'released-dtbs\n' >"${boot}.omarchy-pre-wip"
if TEST_REBUILD_STATUS=1 run_helper main --remove >"$test_tmp/remove-log" 2>&1; then
  fail "--remove fails when update-m1n1 fails"
fi
grep -q 'could not rebuild the shared m1n1 boot image' "$test_tmp/remove-log" ||
  fail "--remove reports why the boot image was not rebuilt"
cmp -s "${boot}.omarchy-pre-wip" <(printf 'released-dtbs\n') ||
  fail "--remove retains the saved boot image when the rebuild fails"
pass "--remove retains the recovery image and reports a failed rebuild"

run_helper main --remove || fail "--remove succeeds after update-m1n1 succeeds"
[[ ! -e ${boot}.omarchy-pre-wip ]] || fail "--remove clears the saved image after a successful rebuild"
pass "--remove clears the recovery snapshot only after the rebuild succeeds"
