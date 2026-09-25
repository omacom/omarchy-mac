#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/test/fixtures/limine-mac.sh"

require_command gzip
require_command b2sum

# omarchy update runs update-verify through omarchy-lifecycle-dispatch once its
# packages, migrations and hooks are done. It is the boot check on the whole
# boot chain, read-only, with the reboot the update offers next still to come.
entrypoint=$ROOT/entrypoints/update-verify
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash "$ROOT/install" "$tmp/stage"
staged=$tmp/stage/usr/lib/omarchy/mac-boot/update-verify
cmp -s "$entrypoint" "$staged" && [[ $(stat -c %a "$staged") == 755 ]] ||
  fail "update-verify is staged as the lifecycle dispatch entrypoint /usr/lib/omarchy/mac-boot/update-verify"
pass "the package ships update-verify where omarchy-lifecycle-dispatch runs it"

limine_mac_init "$tmp/mac"

tree_state() {
  find "$mac_root" -path "$mac_root/run" -prune -o -print0 | sort -z | xargs -0 stat -c '%n %s %Y %a' 2>/dev/null
  find "$mac_root" -path "$mac_root/run" -prune -o -type f -print0 | sort -z | xargs -0 sha256sum
}

# Runs update-verify on the fixture Mac; $1 is the running kernel release.
verify() {
  tree_state >"$tmp/before"
  set +e
  (
    eval "$(limine_mac_env "$ROOT/bin" "${1:-}")"
    bash "$entrypoint"
  ) >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
  tree_state >"$tmp/after"
  diff -q "$tmp/before" "$tmp/after" >/dev/null || fail "update-verify changes no boot file" "$(diff "$tmp/before" "$tmp/after")"
  [[ ! -s $mac_state/mounts && -z $(ls -A "$mac_root/run") ]] || fail "update-verify leaves nothing mounted"
}

expect_verified() {
  (( status == 0 )) || fail "$1 passes update-verify" "status $status: $(cat "$tmp/err")"
}

expect_refused() {
  local description=$1 reason=$2
  (( status == 1 )) || fail "$description fails update-verify" "status $status: $(cat "$tmp/out" "$tmp/err")"
  grep -Fq "$reason" "$tmp/err" || fail "$description is named" "$(cat "$tmp/err")"
  grep -Fq "do not reboot yet" "$tmp/err" && grep -Fq "sudo mkinitcpio -P && sudo update-m1n1 && sudo omarchy-mac-boot-update" "$tmp/err" ||
    fail "$description says not to reboot and how to rebuild the boot files" "$(cat "$tmp/err")"
}

limine_mac
verify
expect_verified "a Limine Mac running the installed kernel"
grep -Fq "running linux-aurora $mac_kver; installed boot files match" "$tmp/out" || fail "update-verify reports what it verified" "$(cat "$tmp/out")"
verify 6.16.0-aurora9-ARCH
expect_verified "a Limine Mac whose update installed a new kernel"
grep -Fq "running 6.16.0-aurora9-ARCH, reboot pending" "$tmp/out" || fail "update-verify says the reboot is still to come" "$(cat "$tmp/out")"
limine_mac_boot_bin "$mac_root/usr/lib/asahi-boot/m1n1.bin" "${mac_dtbs[2]}" "${mac_dtbs[0]}" "${mac_dtbs[1]}"
verify
expect_verified "an m1n1 image holding the kernel's device trees in another order"
pass "update-verify passes a coherent boot chain, before and after the reboot, whatever order the device trees are in"

boot_bin_reason="m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1, linux-aurora $mac_kver's device trees, U-Boot and /etc/m1n1.conf as installed"

limine_mac
limine_mac_dtb "$mac_root/opt/t8103-j274.dtb" "from another kernel"
limine_mac_boot_bin "$mac_root/usr/lib/asahi-boot/m1n1.bin" "${mac_dtbs[@]:0:2}" /opt/t8103-j274.dtb
verify
expect_refused "an m1n1 image with a device tree the installed kernel does not ship" "$boot_bin_reason"

limine_mac
printf 'm1n1 stage 2 from the previous m1n1-aurora\n' >"$tmp/m1n1.bin"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
verify
expect_refused "an m1n1 image with a stale m1n1" "$boot_bin_reason"

limine_mac
rm "$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
verify
expect_refused "a Limine Mac without its UKI" "/boot/efi/EFI/Linux/omarchy_linux-aurora.efi (the Limine UKI) is missing"

limine_mac
printf 'the previous kernel\n' >"$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
limine_mac_menu
verify
expect_refused "a UKI carrying another kernel" "does not carry the installed $mac_kver kernel"

limine_mac
printf 'LIMINE, previous release\n' >"$mac_esp/EFI/BOOT/BOOTAA64.EFI"
verify
expect_refused "a loader slot with another Limine" "/boot/efi/EFI/BOOT/BOOTAA64.EFI is not the installed Limine"

limine_mac
printf 'usr/lib/modules/6.16.0-aurora9-ARCH/kernel/x.ko\n' >"$mac_state/initramfs"
verify 6.16.0-aurora9-ARCH
expect_refused "an initramfs built for the previous kernel" "does not hold the $mac_kver modules"
pass "update-verify refuses a wrong device tree, a stale m1n1, a missing or stale UKI, another Limine or a stale initramfs, and says not to reboot"

# update-verify checks only what the next boot reads. What the full boot check
# also holds against a Mac, the next boot does not read, so it never fails an
# update: the full check still refuses it.
full_check() {
  set +e
  (
    eval "$(limine_mac_env "$ROOT/bin")"
    bash "$ROOT/bin/omarchy-apple-silicon-boot-check"
  ) >"$tmp/full-out" 2>"$tmp/full-err"
  full_status=$?
  set -e
}

beyond_boot_chain() {
  local description=$1 reason=$2
  full_check
  (( full_status == 1 )) && grep -Fq "$reason" "$tmp/full-err" ||
    fail "the full boot check refuses $description" "status $full_status: $(cat "$tmp/full-err")"
  verify
  expect_verified "$description"
}

limine_mac
limine_mac_luks
full_check
(( full_status == 0 )) || fail "the full boot check passes an encrypted Limine Mac" "$(cat "$tmp/full-err")"
verify
expect_verified "an encrypted Limine Mac"
limine_mac_luks 1
beyond_boot_chain "an encrypted Mac with a third LUKS keyslot" "throwaway LUKS keyslot still present"
limine_mac
printf 'M1N1_UPDATE_DISABLED=1\n' >>"$mac_root/etc/default/update-m1n1"
printf 'built by its owner\n' >>"$mac_esp/m1n1/boot.bin"
beyond_boot_chain "an m1n1 image its owner took over" "M1N1_UPDATE_DISABLED is set"
grep -Fq "m1n1/boot.bin is its owner's and is not checked" "$tmp/out" || fail "update-verify says it left m1n1 to its owner" "$(cat "$tmp/out")"
limine_mac
printf 'linux-asahi\n' >>"$mac_state/installed"
beyond_boot_chain "a Mac with a second kernel installed" "cannot tell which kernel boots"
grep -Fq "running linux-aurora $mac_kver" "$tmp/out" || fail "update-verify checks the kernel whose m1n1 is installed" "$(cat "$tmp/out")"
limine_mac
: >"$mac_state/drift-linux-aurora"
beyond_boot_chain "a kernel package file that drifted from its mtree" "linux-aurora files do not match the package mtree"
pass "update-verify passes a healthy Mac with an extra keyslot, an owner-built m1n1, a second kernel or drifted package files"

limine_mac
limine_mac_luks
printf 'usr/lib/modules/%s/kernel/x.ko\nusr/bin/init\n' "$mac_kver" >"$mac_state/initramfs"
verify
expect_refused "an encrypted Mac whose initramfs cannot unlock the root" "does not contain sd-encrypt"
limine_mac
limine_mac_luks
mac_cmdline="root=UUID=r rw rootflags=subvol=@ quiet"
limine_mac_menu
verify
expect_refused "an encrypted Mac whose Limine entry does not unlock the root" "does not set rd.luks.name= for the encrypted root"
pass "update-verify still refuses an encrypted Mac whose next boot cannot unlock its root"
