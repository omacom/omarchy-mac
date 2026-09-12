#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-boot-rebuild must pick GRUB when Limine is absent, embed or drop the
# provisioning cryptkey, and copy the factory vmlinuz onto the ESP before
# mkinitcpio. The helper is executed (not sourced) against a fixture tree so
# this never touches the running system's /boot.

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stub_bin="$work/bin"
mkdir -p "$stub_bin"

write_stub() {
  printf '%s\n' "$2" >"$stub_bin/$1"
  chmod +x "$stub_bin/$1"
}

write_stub omarchy-cmd-present '#!/bin/bash
for cmd in "$@"; do
  command -v "$cmd" &>/dev/null || exit 1
done
'

write_stub mkinitcpio '#!/bin/bash
printf "mkinitcpio %s\n" "$*" >>"$TEST_LOG"
'

write_stub grub-mkconfig '#!/bin/bash
printf "grub-mkconfig %s\n" "$*" >>"$TEST_LOG"
install -D /dev/null "$OMARCHY_BOOT_REBUILD_ROOT/boot/grub/grub.cfg"
if grep -qF cryptkey=rootfs:/etc/omarchy/provisioning.key "$OMARCHY_BOOT_REBUILD_ROOT/etc/default/grub"; then
  printf "cryptkey=rootfs:/etc/omarchy/provisioning.key\n" >>"$OMARCHY_BOOT_REBUILD_ROOT/boot/grub/grub.cfg"
fi
'

write_stub limine-update '#!/bin/bash
printf "limine-update\n" >>"$TEST_LOG"
'

run_rebuild() {
  env PATH="$stub_bin:$ROOT/bin:$PATH" \
    OMARCHY_BOOT_REBUILD_ROOT="$1" \
    TEST_LOG="$2" \
    "$ROOT/bin/omarchy-boot-rebuild"
}

make_grub_root() {
  local root=$1
  mkdir -p "$root/etc/default" "$root/boot/grub" "$root/usr/lib/modules/9.9.9-test/kernel" \
    "$root/etc/mkinitcpio.d" "$root/etc/omarchy"
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=UUID=abc:root:allow-discards quiet splash"\n' \
    >"$root/etc/default/grub"
  printf 'ALL_kver="/boot/vmlinuz-linux-asahi"\n' >"$root/etc/mkinitcpio.d/linux-asahi.preset"
  printf 'kernel\n' >"$root/usr/lib/modules/9.9.9-test/vmlinuz"
}

# --- GRUB + provisioning key: cryptkey is added, vmlinuz is copied ----------

grub_root="$work/grub-key"
make_grub_root "$grub_root"
printf 'throwaway\n' >"$grub_root/etc/omarchy/provisioning.key"
: >"$work/grub-key.log"
run_rebuild "$grub_root" "$work/grub-key.log"

grep -Fxq 'mkinitcpio -P' "$work/grub-key.log" ||
  fail "GRUB rebuild runs mkinitcpio -P" "$(cat "$work/grub-key.log")"
grep -q 'grub-mkconfig -o' "$work/grub-key.log" ||
  fail "GRUB rebuild runs grub-mkconfig" "$(cat "$work/grub-key.log")"
! grep -q 'limine-update' "$work/grub-key.log" ||
  fail "GRUB rebuild does not call limine-update" "$(cat "$work/grub-key.log")"
grep -qF 'cryptkey=rootfs:/etc/omarchy/provisioning.key' "$grub_root/etc/default/grub" ||
  fail "provisioning key adds cryptkey= to GRUB_CMDLINE_LINUX_DEFAULT"
[[ -f $grub_root/boot/vmlinuz-linux-asahi ]] || fail "linux-asahi vmlinuz is copied onto the ESP"
[[ $(cat "$grub_root/boot/vmlinuz-linux-asahi") == "kernel" ]] ||
  fail "copied vmlinuz matches the factory image"
grep -qF 'cryptkey=rootfs:/etc/omarchy/provisioning.key' "$grub_root/boot/grub/grub.cfg" ||
  fail "generated grub.cfg carries cryptkey="
pass "GRUB rebuild embeds the provisioning key and factory vmlinuz"

# --- GRUB without the keyfile: leftover cryptkey is stripped ----------------

grub_strip="$work/grub-strip"
make_grub_root "$grub_strip"
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="|GRUB_CMDLINE_LINUX_DEFAULT="cryptkey=rootfs:/etc/omarchy/provisioning.key |' \
  "$grub_strip/etc/default/grub"
: >"$work/grub-strip.log"
run_rebuild "$grub_strip" "$work/grub-strip.log"

grep -qF 'cryptkey=rootfs:/etc/omarchy/provisioning.key' "$grub_strip/etc/default/grub" &&
  fail "cryptkey= is removed when the provisioning keyfile is gone" \
    "$(cat "$grub_strip/etc/default/grub")"
grep -qF 'cryptdevice=UUID=abc:root:allow-discards quiet splash' "$grub_strip/etc/default/grub" ||
  fail "stripping cryptkey= leaves the rest of the GRUB cmdline"
! grep -qF 'cryptkey=' "$grub_strip/boot/grub/grub.cfg" ||
  fail "generated grub.cfg has no leftover cryptkey="
pass "GRUB rebuild drops cryptkey= after the provisioning keyfile is removed"

# --- Limine present: GRUB tools are not invoked -----------------------------

write_stub limine '#!/bin/bash
exit 0
'
limine_root="$work/limine"
mkdir -p "$limine_root/etc/default"
: >"$work/limine.log"
run_rebuild "$limine_root" "$work/limine.log"

grep -Fxq 'limine-update' "$work/limine.log" ||
  fail "Limine rebuild runs limine-update" "$(cat "$work/limine.log")"
! grep -q 'mkinitcpio' "$work/limine.log" ||
  fail "Limine rebuild does not run mkinitcpio" "$(cat "$work/limine.log")"
! grep -q 'grub-mkconfig' "$work/limine.log" ||
  fail "Limine rebuild does not run grub-mkconfig" "$(cat "$work/limine.log")"
pass "Limine rebuild uses limine-update and leaves GRUB alone"
