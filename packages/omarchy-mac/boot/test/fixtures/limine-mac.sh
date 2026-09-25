# A Limine Mac for omarchy-apple-silicon-boot-check, as a fixture root plus the
# stubs and environment the check reads it through. Sourced by tests;
# limine_mac_init <directory> sets it up, limine_mac lays out a healthy Mac on
# linux-aurora and m1n1-aurora, and limine_mac_env prints the environment.

limine_mac_init() {
  mac_dir=$1
  mac_root=$mac_dir/root
  mac_stubs=$mac_dir/stubs
  mac_state=$mac_dir/state
  mac_kver=6.17.0-aurora1-ARCH
  mac_esp=$mac_root/boot/efi
  mkdir -p "$mac_stubs"

  cat >"$mac_stubs/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
  cat >"$mac_stubs/pacman" <<'SH'
#!/bin/bash
case "$*" in
  -Qq) cat "$MAC_STATE/installed" ;;
  "-Qlq "*) [[ -f $MAC_STATE/files-$2 ]] && cat "$MAC_STATE/files-$2" ;;
  "-Qkk "*)
    if [[ -e $MAC_STATE/drift-$2 ]]; then
      printf 'warning: %s: /usr/lib/modules/x/kernel/drift.ko.zst (Size mismatch)\n' "$2" >&2
      printf '%s: 2 total files, 1 altered files\n' "$2"
      exit 1
    fi
    printf '%s: 2 total files, 0 altered files\n' "$2"
    ;;
  *) exit 1 ;;
esac
SH
  cat >"$mac_stubs/lsinitcpio" <<'SH'
#!/bin/bash
[[ -f ${@: -1} ]] || exit 1
case $1 in
  -l) cat "$MAC_STATE/initramfs" ;;
  -a) printf '==> Image: initramfs\n' ;;
  *) exit 1 ;;
esac
SH
  # Only read-only binds, of a directory standing in for the mounted ESP.
  cat >"$mac_stubs/mount" <<'SH'
#!/bin/bash
[[ $1 == "--bind" && $2 == "-o" && $3 == "ro" && -d $4 ]] || exit 32
cp -a "$4/." "$5/"
echo "$5" >>"$MAC_STATE/mounts"
SH
  cat >"$mac_stubs/umount" <<'SH'
#!/bin/bash
find "$1" -mindepth 1 -delete
sed -i "\|^$1\$|d" "$MAC_STATE/mounts"
SH
  cat >"$mac_stubs/findmnt" <<'SH'
#!/bin/bash
[[ $* == "-n -o VFS-OPTIONS --mountpoint "* ]] && grep -Fxq -- "${@: -1}" "$MAC_STATE/mounts" || exit 1
echo ro,relatime
SH
  cat >"$mac_stubs/lsblk" <<'SH'
#!/bin/bash
exit 0
SH
  cat >"$mac_stubs/blkid" <<'SH'
#!/bin/bash
exit 2
SH
  cat >"$mac_stubs/cryptsetup" <<'SH'
#!/bin/bash
[[ $1 == luksDump && -f $MAC_STATE/luks-dump ]] || exit 1
cat "$MAC_STATE/luks-dump"
SH
  # A fixture UKI is the kernel followed by a marker: .linux is the whole file.
  cat >"$mac_stubs/objcopy" <<'SH'
#!/bin/bash
[[ $* == "-O binary --only-section=.linux "* ]] || exit 1
cp "$4" "$5"
SH
  chmod +x "$mac_stubs"/*
}

# A device tree as update-m1n1 and the boot check see one: the flattened device
# tree magic and big-endian total size, then a body naming it.
limine_mac_dtb() {
  local path=$1 body size
  body="device tree ${path##*/} ${2:-}"$'\n'
  size=$(( 8 + ${#body} ))
  mkdir -p "$(dirname "$path")"
  {
    printf '\xd0\x0d\xfe\xed'
    printf "$(printf '\\x%02x' $(( size >> 24 & 255 )) $(( size >> 16 & 255 )) $(( size >> 8 & 255 )) $(( size & 255 )))"
    printf '%s' "$body"
  } >"$path"
}

# m1n1/boot.bin on the ESP as update-m1n1 writes it: m1n1, the given device
# trees (root-relative), gzipped U-Boot and the m1n1.conf options.
limine_mac_boot_bin() {
  local m1n1=$1 dtb paths=()
  shift
  for dtb; do
    paths+=("$mac_root$dtb")
  done
  {
    cat "$m1n1" "${paths[@]}"
    gzip -c "$mac_root/usr/lib/asahi-boot/u-boot-nodtb.bin"
    printf 'display=2560x1600\n'
  } >"$mac_esp/m1n1/boot.bin"
}

# The Limine menu entry for the UKI, with the hash Limine verifies.
limine_mac_menu() {
  local uki=$mac_esp/EFI/Linux/omarchy_linux-aurora.efi
  printf '/+Omarchy\n  //linux-aurora\n    protocol: efi\n    path: boot():/EFI/Linux/omarchy_linux-aurora.efi#%s\n    cmdline: %s\n' \
    "$(b2sum "$uki" | cut -d' ' -f1)" "$mac_cmdline" >"$mac_esp/limine.conf"
}

limine_mac() {
  local modules=$mac_root/usr/lib/modules/$mac_kver dtb
  mac_dtbs=(/usr/lib/modules/$mac_kver/dtbs/t6000-j314s.dtb /usr/lib/modules/$mac_kver/dtbs/t6020-j414s.dtb /usr/lib/modules/$mac_kver/dtbs/t8103-j274.dtb)
  mac_cmdline="root=UUID=r rw rootflags=subvol=@ quiet"
  rm -rf "$mac_root" "$mac_state"
  mkdir -p "$modules/dtbs" "$mac_root/usr/lib/asahi-boot" "$mac_root/usr/bin" "$mac_root/usr/share/limine" \
    "$mac_root/etc/default" "$mac_root/var/lib/omarchy" "$mac_root/run" \
    "$mac_esp/m1n1" "$mac_esp/EFI/BOOT" "$mac_esp/EFI/Linux" "$mac_state"
  : >"$mac_state/mounts"
  ln -s usr/lib "$mac_root/lib"

  printf 'linux-aurora kernel %s\n' "$mac_kver" >"$modules/vmlinuz"
  cp "$modules/vmlinuz" "$mac_root/boot/vmlinuz-linux-aurora"
  printf 'initramfs\n' >"$mac_root/boot/initramfs-linux-aurora.img"
  printf 'usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\nusr/bin/init\n' "$mac_kver" >"$mac_state/initramfs"
  for dtb in "${mac_dtbs[@]}"; do
    limine_mac_dtb "$mac_root$dtb"
  done
  printf 'm1n1 stage 2 from m1n1-aurora\n' >"$mac_root/usr/lib/asahi-boot/m1n1.bin"
  printf 'u-boot\n' >"$mac_root/usr/lib/asahi-boot/u-boot-nodtb.bin"
  printf 'display=2560x1600\n' >"$mac_root/etc/m1n1.conf"
  printf 'export LC_ALL=C\n' >"$mac_root/etc/default/update-m1n1"
  # update-m1n1 as asahi-scripts ships it, with the DTBS default ALARM adds.
  cat >"$mac_root/usr/bin/update-m1n1" <<'SH'
#!/bin/sh
set -e
[ -e /etc/default/update-m1n1 ] && . /etc/default/update-m1n1
[ -n "$M1N1_UPDATE_DISABLED" ] && exit 0
: ${SOURCE:="/usr/lib/asahi-boot/"}
: ${M1N1:="$SOURCE/m1n1.bin"}
: ${U_BOOT:="$SOURCE/u-boot-nodtb.bin"}
: ${TARGET:="$1"}
: ${DTBS:=$(/bin/ls -d /lib/modules/*-ARCH | sort -rV | head -1)/dtbs/*.dtb}
: ${CONFIG:=/etc/m1n1.conf}
m1n1config=/run/m1n1.conf
if [ -e "$CONFIG" ]; then
    while read line; do
        case "$line" in
            "") ;;
            \#*) ;;
            chosen.*=*|display=*|mitigations=*)
                echo "$line" >> "$m1n1config"
                ;;
        esac
    done <$CONFIG
fi
cat "$M1N1" $DTBS >"${TARGET}.new"
gzip -c "$U_BOOT" >>"${TARGET}.new"
cat "$m1n1config" >>"${TARGET}.new"
SH
  limine_mac_boot_bin "$mac_root/usr/lib/asahi-boot/m1n1.bin" "${mac_dtbs[@]}"

  : >"$mac_root/var/lib/omarchy/limine.enabled"
  printf 'ESP_PATH="/boot/efi"\nENABLE_UKI=yes\n' >"$mac_root/etc/default/limine"
  printf 'UUID=r / btrfs rw,subvol=/@ 0 0\n' >"$mac_root/etc/fstab"
  printf 'LIMINE\n' >"$mac_root/usr/share/limine/BOOTAA64.EFI"
  cp "$mac_root/usr/share/limine/BOOTAA64.EFI" "$mac_esp/EFI/BOOT/BOOTAA64.EFI"
  { cat "$modules/vmlinuz"; printf 'initrd\n'; } >"$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
  limine_mac_menu

  printf '%s\n' linux-aurora m1n1-aurora uboot-asahi limine >"$mac_state/installed"
  {
    printf '/usr/\n/usr/lib/\n/usr/lib/modules/\n/usr/lib/modules/%s/\n/usr/lib/modules/%s/vmlinuz\n/usr/lib/modules/%s/dtbs/\n' "$mac_kver" "$mac_kver" "$mac_kver"
    printf '%s\n' "${mac_dtbs[@]}"
  } >"$mac_state/files-linux-aurora"
  printf '/usr/lib/asahi-boot/\n/usr/lib/asahi-boot/m1n1.bin\n' >"$mac_state/files-m1n1-aurora"
}

# Makes the fixture an encrypted Mac whose owner setup finished: crypttab, the
# Limine entry's rd.luks.name=, a systemd initramfs with the cryptsetup
# generator, and the owner and recovery keyslots. $1 adds keyslots beyond those.
limine_mac_luks() {
  local uuid=0422663f-9969-4953-900f-b342703b7e84 slot
  printf '/dev/mapper/root / btrfs rw,subvol=/@ 0 0\n' >"$mac_root/etc/fstab"
  printf 'root UUID=%s none luks\n' "$uuid" >"$mac_root/etc/crypttab"
  printf 'usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\nusr/bin/init\nusr/bin/systemd-cryptsetup\nusr/lib/systemd/system-generators/systemd-cryptsetup-generator\n' \
    "$mac_kver" >"$mac_state/initramfs"
  mkdir -p "$mac_root/boot/omarchy"
  printf 'format=1\nphase=finished\npartition=p\nluks_uuid=%s\nowner_slot=0\nrecovery_slot=1\n' "$uuid" >"$mac_root/boot/omarchy/encrypt.state"
  {
    printf 'LUKS header information\nKeyslots:\n'
    for (( slot = 0; slot < 2 + ${1:-0}; slot++ )); do
      printf '  %s: luks2\n' "$slot"
    done
  } >"$mac_state/luks-dump"
  mac_cmdline="root=UUID=r rw rootflags=subvol=@ rd.luks.name=$uuid=root quiet"
  limine_mac_menu
}

# The environment the check reads the fixture through, one export per line:
# $1 is where the boot check is, $2 the running kernel release (by default the
# installed one).
limine_mac_env() {
  printf 'export %s\n' \
    "$(printf 'MAC_STATE=%q' "$mac_state")" \
    "$(printf 'OMARCHY_BOOT_CHECK_ROOT=%q' "$mac_root")" \
    "$(printf 'OMARCHY_BOOT_CHECK_UNAME=%q' "${2:-$mac_kver}")" \
    "$(printf 'PATH=%q' "$mac_stubs:$1:$PATH")"
}
