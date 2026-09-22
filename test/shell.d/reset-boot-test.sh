#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/install/helpers/reset-boot.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
cat >"$test_tmp/asahi.preset" <<'PRESET'
# stock Asahi form
ALL_kver="/boot/vmlinuz-linux-asahi"
PRESETS=('default')
default_image="/boot/initramfs-linux-asahi.img"
PRESET
reset_boot_read_preset "$test_tmp/asahi.preset"
[[ $RESET_BOOT_PRESET_KVER == /boot/vmlinuz-linux-asahi && $RESET_BOOT_IMAGE == initramfs-linux-asahi.img ]] || fail 'Asahi preset'
cat >"$test_tmp/generic.preset" <<'PRESET'
ALL_kver="7.2.4-1-aarch64-ARCH"
PRESETS=('default')
default_image="/boot/initramfs-linux.img"
fallback_image="/boot/initramfs-linux-fallback.img"
fallback_options="-S autodetect"
PRESET
reset_boot_read_preset "$test_tmp/generic.preset"
[[ $RESET_BOOT_PRESET_KVER == 7.2.4-1-aarch64-ARCH && $RESET_BOOT_IMAGE == initramfs-linux.img ]] || fail 'generic package preset'
pass 'stock Asahi and generic ARM default presets parsed without evaluation'
cp "$test_tmp/asahi.preset" "$test_tmp/custom.preset"
echo 'default_options="-S encrypt"' >>"$test_tmp/custom.preset"
if reset_boot_read_preset "$test_tmp/custom.preset"; then fail 'custom options silently lost'; fi
cp "$test_tmp/asahi.preset" "$test_tmp/custom.preset"
echo 'touch /unexpected' >>"$test_tmp/custom.preset"
if reset_boot_read_preset "$test_tmp/custom.preset"; then fail 'executable preset'; fi
pass 'unsupported options/commands fail without executing preset'
RESET_BOOT_KERNEL=fixture-version RESET_BOOT_PKGBASE=linux-asahi RESET_BOOT_KERNEL_FILE=vmlinuz-linux-asahi RESET_BOOT_IMAGE=initramfs-linux-asahi.img
RESET_BOOT_ROOT_UUID=11111111-1111-1111-1111-111111111111 RESET_BOOT_UUID=ABCD-1234 RESET_BOOT_LUKS_UUID=""
TEST_ROOT="$test_tmp/root" STAGE="$test_tmp/stage"
mkdir -p "$TEST_ROOT/usr/lib/modules/$RESET_BOOT_KERNEL" "$STAGE/files/grub"
printf 'kernel\n' >"$STAGE/files/$RESET_BOOT_KERNEL_FILE"
sha256sum "$STAGE/files/$RESET_BOOT_KERNEL_FILE" >"$STAGE/kernel-input"
printf 'kernel/fs/btrfs/btrfs.ko\n' >"$TEST_ROOT/usr/lib/modules/$RESET_BOOT_KERNEL/modules.builtin"
chroot() {
  case $2 in
    /usr/bin/grub-script-check) return 0 ;;
    /usr/bin/lsinitcpio) printf '%s\n' "usr/lib/modules/$RESET_BOOT_KERNEL/" "${DECRYPT_CONTENTS:-}" "${KEY_CONTENTS:-}" ;;
    *) return 99 ;;
  esac
}
new_cfg() {
  cat >"$STAGE/files/grub/grub.cfg" <<CFG
search --fs-uuid --set=root '$RESET_BOOT_ROOT_UUID'
menuentry 'Fixture' {
  search --fs-uuid --set=root '$RESET_BOOT_UUID'
  linux /$RESET_BOOT_KERNEL_FILE root=UUID=$RESET_BOOT_ROOT_UUID rootflags=subvol=@
  initrd /$RESET_BOOT_IMAGE
}
CFG
}
new_cfg
reset_boot_verify "$TEST_ROOT" "$STAGE" owner
pass 'verified root and distinct boot selectors accepted'
sed -i "s|initrd /$RESET_BOOT_IMAGE|initrd /initramfs-linux-asahi-fallback.img|" "$STAGE/files/grub/grub.cfg"
if reset_boot_verify "$TEST_ROOT" "$STAGE" owner; then fail 'stale fallback accepted'; fi
pass 'every emitted initrd must be the rebuilt exact payload'
new_cfg
sed -i '/initrd /d' "$STAGE/files/grub/grub.cfg"
if reset_boot_verify "$TEST_ROOT" "$STAGE" owner; then fail 'missing initrd accepted'; fi
pass 'missing initrd rejected'
new_cfg
sed -i "s/$RESET_BOOT_UUID/FFFF-FFFF/" "$STAGE/files/grub/grub.cfg"
if reset_boot_verify "$TEST_ROOT" "$STAGE" owner; then fail 'wrong boot search accepted'; fi
pass 'boot payload filesystem UUID checked in entry context'
new_cfg
RESET_BOOT_LUKS_UUID=22222222-2222-2222-2222-222222222222
if reset_boot_verify "$TEST_ROOT" "$STAGE" owner; then fail 'encrypted root lacks cryptdevice'; fi
sed -i "s|rootflags=subvol=@|rootflags=subvol=@ cryptdevice=UUID=$RESET_BOOT_LUKS_UUID:root|" "$STAGE/files/grub/grub.cfg"
DECRYPT_CONTENTS=$'hooks/encrypt\nusr/bin/cryptsetup\nusr/lib/modules/fixture-version/kernel/drivers/md/dm-crypt.ko.zst'
reset_boot_verify "$TEST_ROOT" "$STAGE" owner
KEY_CONTENTS=etc/omarchy/provisioning.key
if reset_boot_verify "$TEST_ROOT" "$STAGE" owner; then fail 'owner image retains auto-unlock key'; fi
pass 'encrypted identity/decrypt payload and owner key absence gates'
# Match the actual caller spelling: /run can contain the disk-backed top-level
# mount. This path guard is read-only and uses the probed filesystem identity.
findmnt() { if [[ ${*: -1} == FSTYPE ]]; then echo "$STAGE_FS"; else echo "$RESET_BOOT_ROOT_UUID"; fi; }
STAGE_FS=btrfs
reset_boot_stage_path_valid "$RESET_BOOT_ROOT_UUID" /run/omarchy-factory-stage-fixture
STAGE_FS=tmpfs
if reset_boot_stage_path_valid "$RESET_BOOT_ROOT_UUID" /run/omarchy-factory-stage-fixture; then fail 'RAM staging accepted'; fi
pass 'actual filesystem backing governs run-path staging acceptance'

mount() { printf '%s\n' "$*" >>"$test_tmp/mount.log"; }
mkdir -p "$test_tmp/next/boot"
reset_boot_bind_staged_root "$test_tmp/next"
reset_boot_bind_staged_root /
mapfile -t root_mount_calls <"$test_tmp/mount.log"
[[ ${#root_mount_calls[@]} == 1 && ${root_mount_calls[0]} == "--bind $test_tmp/next $test_tmp/next" ]] || fail 'staged root mount visibility'
pass 'staged subvolume is exposed as a mount while the real root needs no bind'
: >"$test_tmp/mount.log"
reset_boot_bind_boot_readonly "$test_tmp/next"
mapfile -t mount_calls <"$test_tmp/mount.log"
[[ ${#mount_calls[@]} == 2 ]] || fail 'unexpected boot bind call count'
[[ ${mount_calls[0]} == "--bind /boot $test_tmp/next/boot" ]] || fail 'live boot was not bind-mounted'
[[ ${mount_calls[1]} == "-o remount,bind,ro $test_tmp/next/boot" ]] || fail 'private boot view was not made read-only'
pass 'private boot view reuses the mounted VFAT without changing superblock state'
