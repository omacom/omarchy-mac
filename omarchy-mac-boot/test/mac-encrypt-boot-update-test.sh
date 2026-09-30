#!/bin/bash
# Exercise conversion completion with a directory root and stubbed device operations.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/files/usr/lib/omarchy/initcpio/omarchy-mac-encrypt"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
ROOT_MNT=$tmp/root
ROOT_DEV=$tmp/device
BOOT_KEY=$tmp/key
calls=$tmp/calls
mkdir -p "$ROOT_MNT/etc/default" "$ROOT_MNT/usr/bin" "$ROOT_MNT/var/lib/omarchy"
printf 'dummy-key' >"$BOOT_KEY"
cryptsetup() { echo dummy-uuid; }
omarchy_mac_encrypt_fail() { echo "$*" >&2; exit 71; }
omarchy_mac_encrypt_write_state() { echo "phase=$1" >>"$calls"; }
for fn in open resize_luks mount_opened set_grub_cmdline esp_writable bind_chroot umount_root esp_readonly; do
  eval "omarchy_mac_encrypt_$fn() { :; }"
done
sync() { :; }
chroot() { printf '%s\n' "$*" >>"$calls"; [[ ${FAIL_UPDATE:-0} != 1 || $2 != omarchy-mac-boot-update ]]; }

touch "$ROOT_MNT/var/lib/omarchy/limine.enabled"
for missing in defaults updater; do
  : >"$calls"
  rm -f "$ROOT_MNT/etc/default/limine" "$ROOT_MNT/usr/bin/omarchy-mac-boot-update"
  if [[ $missing == "defaults" ]]; then
    touch "$ROOT_MNT/usr/bin/omarchy-mac-boot-update"
    chmod +x "$ROOT_MNT/usr/bin/omarchy-mac-boot-update"
  else
    touch "$ROOT_MNT/etc/default/limine"
  fi
  if (omarchy_mac_encrypt_finish); then fail "missing $missing succeeds"; fi
  ! grep -Eq 'update-grub|mkinitcpio|phase=configured' "$calls" || fail "missing $missing changes boot files or completes conversion"
done

touch "$ROOT_MNT/usr/bin/omarchy-mac-boot-update"
chmod +x "$ROOT_MNT/usr/bin/omarchy-mac-boot-update"
: >"$calls"
if (FAIL_UPDATE=1 omarchy_mac_encrypt_finish); then fail "failed Limine update succeeds"; fi
! grep -Fxq 'phase=configured' "$calls" || fail "failed Limine update completes conversion"
: >"$calls"
omarchy_mac_encrypt_finish
[[ $(tail -1 "$calls") == 'phase=configured' ]] || fail "valid Limine completion does not configure"
grep -Fq 'omarchy-mac-boot-update' "$calls" || fail "valid Limine path skips its updater"
rm "$ROOT_MNT/var/lib/omarchy/limine.enabled"
: >"$calls"
omarchy_mac_encrypt_finish
! grep -Fq 'omarchy-mac-boot-update' "$calls" || fail "plain GRUB path invokes Limine"
echo 'ok - conversion requires complete Limine prerequisites and a successful boot update'
