#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

export OMARCHY_MAC_BOOT_LIB="$ROOT/packages/omarchy-mac/boot/lib"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

stub_bin="$tmp/bin"
calls="$tmp/calls"
next="$tmp/next"
device="$tmp/luks-device"
boot_key="$tmp/boot/omarchy/luks-key"
grub_live="$tmp/live/default/grub"
mkdir -p "$stub_bin" "$next/var/lib/omarchy/provisioning" "$tmp/boot/omarchy" "$tmp/live/default" "$next/etc"
: >"$calls"
: >"$device"

printf 'GRUB_CMDLINE_LINUX="rd.luks.name=abcd-ef=root root=/dev/mapper/root quiet"\n' >"$grub_live"
printf 'root UUID=abcd-ef none luks\n' >"$tmp/live/crypttab"
# Tests point GRUB_DEFAULT and CRYPTTAB at these live copies.

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
exit 0
SH

printf '#!/bin/bash\nexit 1\n' >"$stub_bin/omarchy-mac-limine-active"
chmod +x "$stub_bin/omarchy-mac-limine-active"

cat >"$stub_bin/gum" <<SH
#!/bin/bash
printf 'gum %s\n' "\$*" >>"$calls"
if [[ "\$1" == "input" ]]; then
  printf '%s' "current-pass"
  exit 0
fi
exit 0
SH

printf '0 current-pass\n' >"$tmp/slots"
cat >"$stub_bin/cryptsetup" <<SH
#!/bin/bash
printf 'cryptsetup %s\n' "\$*" >>"$calls"
slots_file="$tmp/slots"
case "\$1" in
  open) exit 0 ;;
  luksAddKey)
    next=\$(awk '{s=\$1} END {print s+1}' "\$slots_file")
    printf '%s throwaway\n' "\$next" >>"\$slots_file"
    exit 0
    ;;
  luksDump)
    awk '{ printf "  %s: luks2\\n", \$1 }' "\$slots_file"
    exit 0
    ;;
  luksKillSlot)
    kill_slot=""
    while ((\$#)); do
      [[ \$1 =~ ^[0-9]+$ ]] && kill_slot=\$1
      shift
    done
    awk -v s="\$kill_slot" '\$1 != s { print }' "\$slots_file" >"\$slots_file.new"
    mv "\$slots_file.new" "\$slots_file"
    exit 0
    ;;
  luksUUID) echo abcd-ef; exit 0 ;;
  *) exit 1 ;;
esac
SH

cat >"$stub_bin/chroot" <<SH
#!/bin/bash
printf 'chroot %s\n' "\$*" >>"$calls"
shift
"\$@"
SH

cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
printf 'mkinitcpio %s\n' "\$*" >>"$calls"
exit 0
SH

cat >"$stub_bin/update-grub" <<SH
#!/bin/bash
printf 'update-grub %s\n' "\$*" >>"$calls"
exit 0
SH

cat >"$stub_bin/update-m1n1" <<SH
#!/bin/bash
printf 'update-m1n1 %s\n' "\$*" >>"$calls"
exit 0
SH

cat >"$stub_bin/mount" <<SH
#!/bin/bash
printf 'mount %s\n' "\$*" >>"$calls"
exit 0
SH

cat >"$stub_bin/umount" <<SH
#!/bin/bash
printf 'umount %s\n' "\$*" >>"$calls"
exit 0
SH

cat >"$stub_bin/btrfs" <<SH
#!/bin/bash
printf 'btrfs %s\n' "\$*" >>"$calls"
exit 0
SH

cat >"$stub_bin/passwd" <<SH
#!/bin/bash
exit 0
SH

chmod +x "$stub_bin"/*

export PATH="$stub_bin:$PATH"
export OMARCHY_PATH="$tmp/omarchy"
export OMARCHY_FACTORY_RESET_SOURCE=1
export OMARCHY_FACTORY_RESET_LOG="$tmp/reset.log"
export OMARCHY_BOOT_LUKS_KEY="$boot_key"
export OMARCHY_ENCRYPT_STATE="$tmp/boot/omarchy/encrypt.state"
export OMARCHY_GRUB_DEFAULT="$grub_live"
export OMARCHY_CRYPTTAB="$tmp/live/crypttab"
export OMARCHY_LUKS_DEVICE="$device"
export OMARCHY_RESET_BACKUP_PARENT="$tmp"
: >"$OMARCHY_FACTORY_RESET_LOG"
mkdir -p "$tmp/omarchy/bin"

# shellcheck disable=SC1091
source "$ROOT/bin/omarchy-system-factory-reset"
export PATH="$stub_bin:$PATH"

printf '#!/bin/bash\necho linux-asahi\n' >"$stub_bin/omarchy-mac-kernel"
chmod +x "$stub_bin/omarchy-mac-kernel"
mkdir -p "$next/usr/lib/modules/test-kernel" "$tmp/live-boot"
printf 'linux-asahi\n' >"$next/usr/lib/modules/test-kernel/pkgbase"
printf 'kernel' >"$next/usr/lib/modules/test-kernel/vmlinuz"
printf 'kernel' >"$tmp/live-boot/vmlinuz-linux-asahi"
export OMARCHY_BOOT_DIR="$tmp/live-boot"

stage_luks_rekey "$next"

[[ -f $next/var/lib/omarchy/provisioning/luks-key ]] || fail "reset stages provisioning luks-key"
[[ ! -e $boot_key ]] || fail "reset does not write the Boot-partition luks-key before rebuilds"
! grep -F 'cryptsetup luksAddKey' "$calls" >/dev/null ||
  fail "reset does not add a throwaway slot before rebuilds" "$(cat "$calls")"
grep -q 'rd.luks.key=abcd-ef=/omarchy/luks-key:UUID=4f4d5801-424f-4f54-8000-000000000001' "$next/etc/default/grub" ||
  fail "reset adds rd.luks.key= to the factory GRUB cmdline" "$(cat "$next/etc/default/grub")"
[[ ! -e $next/etc/omarchy/provisioning.key ]] || fail "Apple reset does not embed a Limine UKI keyfile"
[[ ! -e $next/etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf ]] ||
  fail "Apple reset does not write limine-entry-tool drop-ins"

: >"$calls"
cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
printf 'mkinitcpio %s\n' "\$*" >>"$calls"
exit 1
SH
chmod +x "$stub_bin/mkinitcpio"
if ( rebuild_next_boot "$next" ); then
  fail "a failed initramfs rebuild fails closed"
fi
[[ ! -e $boot_key ]] || fail "a failed rebuild does not leave /boot/omarchy/luks-key"
! grep -F 'cryptsetup luksAddKey' "$calls" >/dev/null ||
  fail "a failed rebuild does not add a throwaway slot" "$(cat "$calls")"
revoke_reset_luks
[[ ! -e $boot_key ]] || fail "cleanup shreds the Boot-partition keyfile"

cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
printf 'mkinitcpio %s\n' "\$*" >>"$calls"
exit 0
SH
chmod +x "$stub_bin/mkinitcpio"

: >"$calls"
rebuild_next_boot "$next"
grep -F 'mkinitcpio -P' "$calls" >/dev/null || fail "reset rebuilds the initramfs" "$(cat "$calls")"
grep -F 'update-grub' "$calls" >/dev/null || fail "reset regenerates grub.cfg" "$(cat "$calls")"
! grep -Eq '^(update-m1n1|chroot .* update-m1n1)' "$calls" || fail "reset preserves ESP firmware" "$(cat "$calls")"
! grep -F 'limine-update' "$calls" >/dev/null || fail "a GRUB Mac's reset does not call limine-update"
[[ ! -e $boot_key ]] || fail "rebuilds still do not write the Boot-partition luks-key"

# A Limine Mac: the ESP's menu starts over from the template, the previous
# identity's history goes, and the factory root rebuilds Limine.
mkdir -p "$next/usr/share/omarchy/default/limine" "$next/boot/efi/0123456789abcdef0123456789abcdef" "$next/usr/bin"
printf 'timeout: 3\ndefault_entry: 2\n' >"$next/usr/share/omarchy/default/limine/limine.conf"
printf 'timeout: 3\n/+Omarchy\ncomment: machine-id=0123456789abcdef0123456789abcdef\n' >"$next/boot/efi/limine.conf"
echo fedcba9876543210fedcba9876543210 >"$next/etc/machine-id"
cat >"$stub_bin/omarchy-mac-limine-active" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$stub_bin/omarchy-mac-boot-update" <<SH
#!/bin/bash
printf 'omarchy-mac-boot-update\n' >>"$calls"
SH
cp "$stub_bin/omarchy-mac-boot-update" "$next/usr/bin/omarchy-mac-boot-update"
chmod +x "$stub_bin/omarchy-mac-limine-active" "$stub_bin/omarchy-mac-boot-update" "$next/usr/bin/omarchy-mac-boot-update"
: >"$calls"
rebuild_next_boot "$next"
grep -F 'omarchy-mac-boot-update' "$calls" >/dev/null || fail "a Limine Mac's reset rebuilds the boot loader through omarchy-mac-boot-update" "$(cat "$calls")"
! grep -q 'machine-id=0123456789abcdef' "$next/boot/efi/limine.conf" || fail "the ESP's limine.conf starts over from the template" "$(cat "$next/boot/efi/limine.conf")"
[[ ! -d $next/boot/efi/0123456789abcdef0123456789abcdef ]] || fail "the previous identity's Limine history is removed"
rm -f "$stub_bin/omarchy-mac-limine-active" "$stub_bin/omarchy-mac-boot-update" "$next/usr/bin/omarchy-mac-boot-update"
pass "a Limine Mac's reset resets Limine's menu and rebuilds it from the factory root"

# Observe state at the slot write, the first persistent temporary credential.
printf 'format=1\nphase=finished\nowner_slot=0\n' >"$OMARCHY_ENCRYPT_STATE"
cp "$stub_bin/cryptsetup" "$stub_bin/cryptsetup.real"
cat >"$stub_bin/cryptsetup" <<'SH'
#!/bin/bash
if [[ $1 == "luksAddKey" ]]; then
  grep -Fxq 'phase=configured' "$OMARCHY_ENCRYPT_STATE" || exit 90
fi
exec "${BASH_SOURCE[0]}.real" "$@"
SH
chmod +x "$stub_bin/cryptsetup"
: >"$calls"
stage_luks_rekey_apple_commit "$RESET_LUKS_DEVICE" "$RESET_THROWAY"
[[ ! -e $boot_key ]] || fail "the Boot-partition luks-key waits for activation"
grep -F 'cryptsetup luksAddKey' "$calls" >/dev/null || fail "reset adds a throwaway LUKS key after rebuilds"
[[ -n $RESET_LUKS_SLOT ]] || fail "reset records the throwaway slot for cleanup"
install_reset_boot_key "$RESET_THROWAY" || fail "the activated reset writes its Boot-partition luks-key"
[[ $(cat "$boot_key") == "$RESET_THROWAY" ]] || fail "the Boot-partition luks-key holds the throwaway passphrase"
[[ $(stat -c '%a' "$boot_key") == "600" ]] || fail "Boot-partition luks-key is mode 600"

: >"$calls"
rm -f "$boot_key"
printf '0 current-pass\n1 throwaway\n' >"$tmp/slots"
RESET_LUKS_SLOT=1
RESET_LUKS_DEVICE=$device
RESET_LUKS_AUTH=current-pass
printf 'leftover' >"$boot_key"
revoke_reset_luks
[[ ! -e $boot_key ]] || fail "cleanup shreds a leftover Boot-partition keyfile"
! grep -q '^1 ' "$tmp/slots" || fail "cleanup revokes the throwaway slot" "$(cat "$tmp/slots")"
grep -F 'cryptsetup luksKillSlot' "$calls" >/dev/null || fail "cleanup calls luksKillSlot"

: >"$calls"
printf 'GRUB_CMDLINE_LINUX="rd.luks.name=old-uuid=root rd.luks.key=stale-uuid=/wrong-key:UUID=FFFF-FFFF root=/dev/mapper/root quiet"\n' \
  >"$next/etc/default/grub"
grub_add_rd_luks_key "$next/etc/default/grub" abcd-ef
grep -q 'rd.luks.key=abcd-ef=/omarchy/luks-key:UUID=4f4d5801-424f-4f54-8000-000000000001' "$next/etc/default/grub" ||
  fail "reset replaces a stale rd.luks.key= token" "$(cat "$next/etc/default/grub")"
! grep -q 'stale-uuid' "$next/etc/default/grub" ||
  fail "reset does not keep a stale rd.luks.key= token" "$(cat "$next/etc/default/grub")"
grep -q 'rd.luks.name=old-uuid=root' "$next/etc/default/grub" ||
  fail "reset keeps the rest of GRUB_CMDLINE_LINUX when replacing rd.luks.key="

printf 'GRUB_TIMEOUT=0\n' >"$next/etc/default/grub"
grub_add_rd_luks_key "$next/etc/default/grub" abcd-ef
grep -q '^GRUB_TIMEOUT=0$' "$next/etc/default/grub" &&
  grep -q '^GRUB_CMDLINE_LINUX="rd.luks.key=abcd-ef=' "$next/etc/default/grub" ||
  fail "reset appends a command line to defaults without one" "$(cat "$next/etc/default/grub")"

printf 'GRUB_CMDLINE_LINUX="quiet"\n' >"$next/etc/default/grub"
chmod 555 "$next/etc/default"
if grub_add_rd_luks_key "$next/etc/default/grub" abcd-ef; then
  chmod 755 "$next/etc/default"
  fail "reset reports a GRUB defaults staging failure"
fi
chmod 755 "$next/etc/default"
[[ $(cat "$next/etc/default/grub") == 'GRUB_CMDLINE_LINUX="quiet"' ]] ||
  fail "a failed staging write leaves the defaults intact" "$(cat "$next/etc/default/grub")"
pass "reset stages rd.luks.key= atomically and reports failed writes"

factory="$tmp/factory"
mkdir -p "$factory/etc" \
  "$factory/var/lib/omarchy/mac-first-boot" \
  "$factory/var/lib/omarchy/provisioning" \
  "$factory/boot/efi/omarchy" \
  "$factory/boot/omarchy"
: >"$factory/etc/passwd"
: >"$factory/etc/machine-id"
touch "$factory/var/lib/omarchy/mac-first-boot/pending" \
  "$factory/var/lib/omarchy/mac-first-boot/install.conf" \
  "$factory/var/lib/omarchy/provisioning/pending" \
  "$factory/var/lib/omarchy/provisioning/wipe-pending" \
  "$factory/boot/efi/omarchy/install.conf"
printf 'format=1\nphase=finished\npartition=p\nluks_uuid=u\n' >"$factory/boot/omarchy/encrypt.state"
sanitize_factory_baseline "$factory"
[[ ! -e $factory/var/lib/omarchy/mac-first-boot/pending ]] || fail "@factory does not keep mac-first-boot/pending"
[[ ! -e $factory/var/lib/omarchy/mac-first-boot/install.conf ]] || fail "@factory does not keep install.conf"
[[ ! -e $factory/var/lib/omarchy/provisioning/pending ]] || fail "@factory does not keep provisioning/pending"
[[ ! -e $factory/var/lib/omarchy/provisioning/wipe-pending ]] || fail "@factory does not keep wipe-pending"
[[ ! -e $factory/boot/efi/omarchy/install.conf ]] || fail "@factory does not keep the ESP install.conf"
# /boot inside a subvolume is an empty mountpoint on a real system: the live
# Boot partition's encrypt.state is reopened before committing the key,
# never by the subvolume scrub.
[[ -f $factory/boot/omarchy/encrypt.state ]] || fail "the subvolume scrub leaves boot/omarchy alone"
live_state="$tmp/boot/omarchy/encrypt.state"
printf 'format=1\nphase=finished\npartition=p\nluks_uuid=u\nowner_slot=1\nrecovery_slot=2\n' >"$live_state"
OMARCHY_ENCRYPT_STATE="$live_state" reopen_encrypt_state
[[ $(cat "$live_state") == $'format=1\nphase=configured\npartition=p\nluks_uuid=u' ]] ||
  fail "reopen_encrypt_state returns the live Boot state to phase=configured without the slots"
printf 'format=1\nphase=declined\npartition=unknown\nluks_uuid=\n' >"$live_state"
OMARCHY_ENCRYPT_STATE="$live_state" reopen_encrypt_state
[[ $(cat "$live_state") == $'format=1\nphase=declined\npartition=unknown\nluks_uuid=' ]] ||
  fail "reopen_encrypt_state keeps a declined encryption declined across a reset"
rm -f "$live_state"
OMARCHY_ENCRYPT_STATE="$live_state" reopen_encrypt_state || fail "reopen_encrypt_state is a no-op without a state file"
[[ ! -e $live_state ]] || fail "reopen_encrypt_state does not invent a state file"

cloned="$tmp/cloned"
mkdir -p "$cloned/var/lib/omarchy/mac-first-boot" "$cloned/boot/omarchy" "$cloned/boot/efi/omarchy"
touch "$cloned/var/lib/omarchy/mac-first-boot/pending" \
  "$cloned/var/lib/omarchy/mac-first-boot/install.conf" \
  "$cloned/boot/efi/omarchy/install.conf"
printf 'format=1\nphase=finished\n' >"$cloned/boot/omarchy/encrypt.state"
scrub_factory_boot_state "$cloned"
arm_reset_markers "$cloned"
[[ -f $cloned/var/lib/omarchy/mac-first-boot/pending ]] || fail "reset re-arms mac-first-boot/pending"
[[ -f $cloned/var/lib/omarchy/provisioning/pending ]] || fail "reset re-arms provisioning/pending"
[[ -f $cloned/var/lib/omarchy/provisioning/wipe-pending ]] || fail "reset re-arms wipe-pending"
[[ ! -e $cloned/var/lib/omarchy/mac-first-boot/install.conf ]] || fail "reset next root does not keep install.conf"
[[ ! -e $cloned/boot/efi/omarchy/install.conf ]] || fail "reset next root does not keep the ESP install.conf"
[[ -f $cloned/boot/omarchy/encrypt.state ]] || fail "the next-root scrub leaves boot/omarchy alone"
pass "LUKS factory reset adds its slot after rebuilds, writes the Boot key after activation, re-arms both markers, and keeps @factory clean"

# Declining a reset before adding its own slot must leave an earlier boot's
# temporary key intact, including a machine still completing first boot.
RESET_LUKS_SLOT=""
printf 'existing-first-boot-key' >"$boot_key"
revoke_reset_luks
[[ $(cat "$boot_key") == "existing-first-boot-key" ]] || fail "an unstarted reset preserves an existing unlock key"
pass "cleanup only removes an unlock key created by this reset"

printf 'different kernel' >"$next/usr/lib/modules/test-kernel/vmlinuz"
: >"$calls"
if (rebuild_next_boot_apple "$next"); then fail "reset rejects a different factory kernel"; fi
! grep -Eq '^(mount|chroot|update-m1n1)' "$calls" || fail "a mismatched kernel changes no boot files"
pass "cross-kernel reset requires a coordinated boot-package restore"

# A failed state flush must stop before adding a key or activating the root.
printf 'format=1\nphase=finished\n' >"$OMARCHY_ENCRYPT_STATE"
: >"$calls"
if (sync() { return 1; }; stage_luks_rekey_apple_commit "$device" throwaway); then
  fail "reset aborts when the reopened phase cannot be persisted"
fi
! grep -Fq 'cryptsetup luksAddKey' "$calls" || fail "state durability failure adds no key"
grep -Fxq 'phase=finished' "$OMARCHY_ENCRYPT_STATE" || fail "failed file sync retains the prior journal"
pass "reset persists an unfinished phase before adding a temporary unlock"

# The sourced reset script replaces fail with its own gum-styled exit; report
# these assertions visibly.
test_fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

# A reset that fails before activation leaves the old root bootable: every
# boot file the rebuild touched on the live Boot partition and ESP returns.
live="$tmp/live-boot"
rm -rf "$tmp"/omarchy-reset-boot.*
mkdir -p "$live/efi/EFI/Linux" "$live/efi/EFI/BOOT" "$live/efi/0123456789abcdef0123456789abcdef" "$live/grub"
printf 'timeout: 3\n/+Omarchy\ncomment: machine-id=0123456789abcdef0123456789abcdef\n  //linux-asahi\n  path: boot():/EFI/Linux/omarchy_linux-asahi.efi#old\n' >"$live/efi/limine.conf"
printf 'old uki' >"$live/efi/EFI/Linux/omarchy_linux-asahi.efi"
printf 'limine' >"$live/efi/EFI/BOOT/BOOTAA64.EFI"
printf 'history' >"$live/efi/0123456789abcdef0123456789abcdef/limine_history"
printf 'old initramfs' >"$live/initramfs-linux-asahi.img"
printf 'old grub.cfg' >"$live/grub/grub.cfg"
before_tree=$(cd "$live" && find . -type f -exec sha256sum {} + | sort)
printf 'kernel' >"$next/usr/lib/modules/test-kernel/vmlinuz"
rm -rf "$next/boot"
ln -s "$live" "$next/boot"
cat >"$stub_bin/omarchy-mac-limine-active" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
printf 'new initramfs' >"$live/initramfs-linux-asahi.img"
printf 'fallback' >"$live/initramfs-linux-asahi-fallback.img"
printf 'new uki' >"$live/efi/EFI/Linux/omarchy_linux-asahi.efi"
exit 1
SH
chmod +x "$stub_bin/omarchy-mac-limine-active" "$stub_bin/mkinitcpio"
if (trap cleanup EXIT; rebuild_next_boot "$next"); then test_fail "a failed factory rebuild fails the reset"; fi
after_tree=$(cd "$live" && find . -type f -exec sha256sum {} + | sort)
[[ $after_tree == "$before_tree" ]] || test_fail "a failed reset restores every live boot file" "$(diff <(echo "$before_tree") <(echo "$after_tree"))"
! compgen -G "$tmp/omarchy-reset-boot.*" >/dev/null || test_fail "a completed restore discards its backup"
rm -f "$stub_bin/omarchy-mac-limine-active"
pass "a reset failing before activation restores the live menu, UKIs, history, initramfs and GRUB"

# A backup that cannot complete stops the reset before any boot file changes
# and never arms a rollback that would delete what it failed to copy.
rm -rf "$tmp"/omarchy-reset-boot.*
chmod 000 "$live/initramfs-linux-asahi.img"
cat >"$stub_bin/omarchy-mac-limine-active" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$stub_bin/omarchy-mac-limine-active"
: >"$calls"
if (trap cleanup EXIT; rebuild_next_boot "$next"); then test_fail "an incomplete backup fails the reset"; fi
chmod 644 "$live/initramfs-linux-asahi.img"
rm -f "$stub_bin/omarchy-mac-limine-active"
after_tree=$(cd "$live" && find . -type f -exec sha256sum {} + | sort)
[[ $after_tree == "$before_tree" ]] || test_fail "an incomplete backup changes no live boot file" "$(diff <(echo "$before_tree") <(echo "$after_tree"))"
! grep -Eq '^(mount|chroot)' "$calls" || test_fail "an incomplete backup stops before the rebuild" "$(cat "$calls")"
! compgen -G "$tmp/omarchy-reset-boot.*" >/dev/null || test_fail "an incomplete backup is removed"
pass "an incomplete boot-file backup stops the reset without touching the live files"

# The rebuilt files are flushed before the reset may add a credential; a
# failed flush fails the reset and restores the previous files.
rm -rf "$tmp"/omarchy-reset-boot.*
cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
printf 'new initramfs' >"$live/initramfs-linux-asahi.img"
exit 0
SH
chmod +x "$stub_bin/mkinitcpio"
if (trap cleanup EXIT; sync() { return 1; }; rebuild_next_boot "$next"); then test_fail "an unflushed rebuild fails the reset"; fi
after_tree=$(cd "$live" && find . -type f -exec sha256sum {} + | sort)
[[ $after_tree == "$before_tree" ]] || test_fail "an unflushed rebuild restores the live boot files" "$(diff <(echo "$before_tree") <(echo "$after_tree"))"
pass "rebuilt boot files are flushed before the reset continues"

# The same failure hands back the finished encryption state it reopened.
printf 'format=1\nphase=finished\npartition=p\nluks_uuid=u\nowner_slot=1\nrecovery_slot=2\n' >"$OMARCHY_ENCRYPT_STATE"
state_before=$(cat "$OMARCHY_ENCRYPT_STATE")
rm -f "$boot_key"
cat >"$stub_bin/cryptsetup" <<'SH'
#!/bin/bash
[[ $1 == "luksAddKey" ]] && exit 1
exec "${BASH_SOURCE[0]}.real" "$@"
SH
chmod +x "$stub_bin/cryptsetup"
RESET_AUTH_FIXTURE=current-pass
if (trap cleanup EXIT; RESET_LUKS_AUTH=$RESET_AUTH_FIXTURE; stage_luks_rekey_apple_commit "$device" throwaway); then
  test_fail "a failed throwaway slot fails the reset"
fi
[[ $(cat "$OMARCHY_ENCRYPT_STATE") == "$state_before" ]] ||
  test_fail "a failed reset restores the finished encryption state" "$(cat "$OMARCHY_ENCRYPT_STATE")"
[[ ! -e $boot_key ]] || test_fail "a failed reset writes no Boot-partition key"
pass "a reset failing before activation restores encrypt.state"

printf 'not a directory' >"$tmp/not-a-dir"
if BOOT_LUKS_KEY="$tmp/not-a-dir/luks-key" install_reset_boot_key throwaway; then
  test_fail "an unwritable Boot partition reports the missing key"
fi
! compgen -G "$tmp/not-a-dir/luks-key.*" >/dev/null || test_fail "a failed key write leaves no staged key"
pass "a failed post-activation key write is reported without leftovers"
