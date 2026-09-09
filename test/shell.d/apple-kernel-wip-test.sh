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
exec "$@"
SH
chmod +x "$stub_bin/sudo"

run_helper() {
  PATH="$stub_bin:$PATH" OMARCHY_M1N1_BOOT_BIN="$boot" bash -c '
    # shellcheck source=/dev/null
    source "$1"
    shift
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

rm -f "${boot}.old"
! run_helper rollback_boot_bin || fail "rollback fails when no saved image exists"
pass "rollback_boot_bin fails closed without a saved image"

grep -q 'not a' "$kernel_wip" && grep -q 'safe fallback' "$kernel_wip" ||
  fail "the command warns that the released GRUB entry is not a safe fallback"
! grep -q 'linux-asahi entry is still there if the branch does not boot' "$kernel_wip" ||
  fail "the old GRUB-fallback log line is gone"
pass "the command does not promise the released kernel is a safe GRUB fallback"
