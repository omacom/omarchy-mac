#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

require_command gzip
require_command realpath
require_command b2sum

check="$ROOT/bin/omarchy-apple-silicon-boot-check"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
root="$test_tmp/root"
calls="$test_tmp/calls"
mounts="$test_tmp/mounts"
esp="$root/boot/efi"
esp_device="$test_tmp/esp-device"
mkdir -p "$stub_bin"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo:%s\n' "$*" >>"$TEST_CALLS"
exec "$@"
SH
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
case "$*" in
  -Qq) cat "$TEST_FILES/installed" ;;
  "-Qlq "*) [[ -f $TEST_FILES/$2 ]] && cat "$TEST_FILES/$2" ;;
  "-Qkk "*) exit 0 ;;
  "-Q "*)
    [[ -f $TEST_FILES/version-$2 ]] || exit 1
    echo "$2 $(cat "$TEST_FILES/version-$2")"
    ;;
  *) exit 1 ;;
esac
SH
cat >"$stub_bin/lsinitcpio" <<'SH'
#!/bin/bash
if [[ "$1" == "-x" ]]; then
  image=${*: -1}
  [[ -f $image ]] || exit 1
  printf 'lsinitcpio -x %s\n' "$*" >>"$TEST_CALLS"
  [[ -z ${TEST_INITRD_TREE:-} ]] || cp -a "$TEST_INITRD_TREE/." .
  exit 0
fi
if [[ "$1" == "-a" && -f "$2" ]]; then
  cat "${TEST_INITRAMFS_ANALYZE:-$TEST_INITRAMFS_LIST.analyze}"
  exit 0
fi
[[ "$1" == "-l" && -f "$2" ]] || exit 1
cat "$TEST_INITRAMFS_LIST"
SH
# A fixture UKI is the kernel followed by a marker: .linux is the whole file.
cat >"$stub_bin/objcopy" <<'SH'
#!/bin/bash
printf 'objcopy %s\n' "$*" >>"$TEST_CALLS"
[[ -f $4 ]] || exit 1
case $3 in
  --only-section=.linux) cp "$4" "$5" ;;
  --only-section=.initrd) printf 'initrd of %s\n' "$4" >"$5" ;;
  *) exit 1 ;;
esac
SH
cat >"$stub_bin/journalctl" <<'SH'
#!/bin/bash
printf 'journalctl %s\n' "$*" >>"$TEST_CALLS"
[[ -z ${TEST_JOURNAL:-} ]] || cat "$TEST_JOURNAL"
SH
cat >"$stub_bin/cryptsetup" <<'SH'
#!/bin/bash
case "$1" in
  luksDump)
    printf 'LUKS header information\nVersion:       \t2\n\nData segments:\n  0: crypt\n\nKeyslots:\n'
    if [[ -n ${TEST_LUKS_SLOTS:-} ]]; then
      for slot in $TEST_LUKS_SLOTS; do
        printf '  %s: luks2\n\tKey:        512 bits\n' "$slot"
      done
    else
      slots=${TEST_LUKS_SLOT_COUNT:-2}
      i=0
      while (( i < slots )); do
        printf '  %s: luks2\n\tKey:        512 bits\n' "$i"
        (( ++i ))
      done
    fi
    # TEST_LUKS_TOKENS holds id:type:keyslot triples; their lines look like keyslots.
    if [[ -n ${TEST_LUKS_TOKENS:-} ]]; then
      echo "Tokens:"
      for token in $TEST_LUKS_TOKENS; do
        IFS=: read -r id type slot <<<"$token"
        printf '  %s: %s\n\tKeyslot:    %s\n' "$id" "$type" "$slot"
      done
    fi
    printf 'Digests:\n  0: pbkdf2\n'
    exit 0
    ;;
  *) exit 1 ;;
esac
SH
cat >"$stub_bin/mount" <<'SH'
#!/bin/bash
printf 'mount %s\n' "$*" >>"$TEST_CALLS"
options="" bind=0 positional=()
while (($#)); do
  case "$1" in
    -o) options=$2; shift 2 ;;
    --bind) bind=1; shift ;;
    *) positional+=("$1"); shift ;;
  esac
done
target=${positional[-1]}
if [[ ,$options, == *,remount,* ]]; then
  sed -i "\|^$target |d" "$TEST_MOUNTS"
  echo "$target ro" >>"$TEST_MOUNTS"
  exit 0
fi
state=rw
[[ ,$options, != *,ro,* ]] || state=ro
if (( bind )); then
  source=${positional[0]}
else
  source=$TEST_ESP_DEVICE
fi
cp -a "$source/." "$target/"
echo "$target $state" >>"$TEST_MOUNTS"
SH
cat >"$stub_bin/umount" <<'SH'
#!/bin/bash
printf 'umount %s\n' "$*" >>"$TEST_CALLS"
find "$1" -mindepth 1 -delete
sed -i "\|^$1 |d" "$TEST_MOUNTS"
SH
cat >"$stub_bin/findmnt" <<'SH'
#!/bin/bash
case "$*" in
  "-n -o VFS-OPTIONS --mountpoint "*)
    state=$(awk -v target="${@: -1}" '$1 == target { print $2 }' "$TEST_MOUNTS")
    [[ -n $state ]] || exit 1
    echo "$state,relatime"
    ;;
  *) exit 1 ;;
esac
SH
cat >"$stub_bin/blkid" <<'SH'
#!/bin/bash
[[ "$*" == *"/dev/mapper/root"* && -n ${TEST_MAPPER_UUID:-} ]] || exit 2
echo "$TEST_MAPPER_UUID"
SH
cat >"$stub_bin/lsblk" <<'SH'
#!/bin/bash
[[ -n ${TEST_LSBLK:-} && -f $TEST_LSBLK ]] && cat "$TEST_LSBLK"
exit 0
SH
chmod +x "$stub_bin"/*

write_update_m1n1() {
  mkdir -p "$root/usr/bin"
  cat >"$root/usr/bin/update-m1n1" <<'SH'
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
if [ -z "$DTBS" ]; then
    exit 1
fi
m1n1config=/run/m1n1.conf
>"$m1n1config"
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
}

write_boot_bin() {
  local dtb paths=()
  for dtb; do
    paths+=("$root$dtb")
  done
  mkdir -p "$esp/m1n1"
  {
    cat "$root/usr/lib/asahi-boot/m1n1.bin" "${paths[@]}"
    gzip -c "$root/usr/lib/asahi-boot/u-boot-nodtb.bin"
    printf 'chosen.asahi,efi-system-partition=1234\ndisplay=2560x1600\nmitigations=off\n'
  } >"$esp/m1n1/boot.bin"
}

system() {
  local kernel=linux-aurora
  kver=6.17.0-aurora1-ARCH
  modules="$root/usr/lib/modules/$kver"
  dtbs=("/usr/lib/modules/$kver/dtbs/t6000-j314s.dtb")
  rm -rf "$root"
  mkdir -p "$modules/dtbs" "$root/boot/grub" "$root/usr/lib/asahi-boot" "$root/etc/default" "$root/run" "$esp/m1n1" "$test_tmp/files"
  : >"$mounts"
  ln -s usr/lib "$root/lib"
  printf '%s kernel %s\n' "$kernel" "$kver" >"$modules/vmlinuz"
  cp "$modules/vmlinuz" "$root/boot/vmlinuz-$kernel"
  printf 'initramfs\n' >"$root/boot/initramfs-$kernel.img"
  printf 'linux /vmlinuz-%s root=UUID=x\ninitrd /initramfs-%s.img\n' "$kernel" "$kernel" >"$root/boot/grub/grub.cfg"
  for dtb in "${dtbs[@]}"; do
    mkdir -p "$(dirname "$root$dtb")"
    printf 'device tree %s\n' "${dtb##*/}" >"$root$dtb"
  done
  printf 'm1n1 stage 2 from m1n1-aurora\n' >"$root/usr/lib/asahi-boot/m1n1.bin"
  printf 'u-boot\n' >"$root/usr/lib/asahi-boot/u-boot-nodtb.bin"
  printf '# options\nchosen.asahi,efi-system-partition=1234\ndisplay=2560x1600\n   mitigations=off\nunknown=1\n\n' >"$root/etc/m1n1.conf"
  write_update_m1n1
  printf '%s\n' linux-aurora linux-aurora-headers m1n1-aurora >"$test_tmp/files/installed"
  {
    printf '/usr/\n/usr/lib/\n/usr/lib/modules/\n/usr/lib/modules/%s/\n/usr/lib/modules/%s/vmlinuz\n' "$kver" "$kver"
    printf '/usr/lib/modules/%s/dtbs/\n' "$kver"
    printf '%s\n' "${dtbs[@]}"
  } >"$test_tmp/files/linux-aurora"
  printf '/usr/lib/asahi-boot/\n/usr/lib/asahi-boot/m1n1.bin\n' >"$test_tmp/files/m1n1-aurora"
  printf 'usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\nusr/bin/init\n' "$kver" >"$test_tmp/initramfs"
  write_boot_bin "${dtbs[@]}"
  # The running kernel is bound to the staged release: descriptor, lane and
  # the installed version pacman -Q reports.
  mkdir -p "$root/var/lib/omarchy"
  {
    printf 'format=1\nchannel=aurora\nrelease_tag=aurora-packages-1c5e34c99dc2510bf06c673165a79aa92c8f1f4c\n'
    printf 'package=1|linux-aurora|6.17.0.aurora1-1|aarch64|linux-aurora.pkg.tar.zst|%064d|linux-aurora.pkg.tar.zst.sig|%064d\n' 1 2
  } >"$root/var/lib/omarchy/aurora-target.descriptor"
  printf 'format=1\nlane=rc\n' >"$root/var/lib/omarchy/apple-silicon-aurora-lane"
  printf 'format=1\nchannel=rc\nkernel=linux-aurora\n' >"$root/var/lib/omarchy/apple-silicon-channel"
  printf '6.17.0.aurora1-1\n' >"$test_tmp/files/version-linux-aurora"
}

run_check() {
  : >"$calls"
  set +e
  env -u LC_ALL -u LC_COLLATE LANG=C \
    TEST_CALLS="$calls" \
    TEST_FILES="$test_tmp/files" \
    TEST_INITRAMFS_LIST="$test_tmp/initramfs" \
    TEST_MOUNTS="$mounts" \
    TEST_ESP_DEVICE="$esp_device" \
    TEST_LUKS_SLOT_COUNT="${TEST_LUKS_SLOT_COUNT:-2}" \
    TEST_LUKS_SLOTS="${TEST_LUKS_SLOTS:-}" \
    TEST_LUKS_TOKENS="${TEST_LUKS_TOKENS:-}" \
    TEST_INITRAMFS_ANALYZE="${TEST_INITRAMFS_ANALYZE:-$test_tmp/initramfs.analyze}" \
    TEST_LSBLK="${TEST_LSBLK:-}" \
    TEST_MAPPER_UUID="${TEST_MAPPER_UUID:-}" \
    OMARCHY_BOOT_CHECK_ROOT="$root" \
    OMARCHY_BOOT_CHECK_UNAME="$kver" \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    bash "$check" ${TEST_BOOT_CHAIN:+--boot-chain} linux-aurora >"$test_tmp/out" 2>"$test_tmp/err"
  status=$?
  set -e
}

expect_pass() {
  (( status == 0 )) || fail "$1 passes" "status $status: $(cat "$test_tmp/err")"
}

expect_fail() {
  local description=$1 message=$2
  (( status == 1 )) || fail "$description fails the check" "status $status: $(cat "$test_tmp/err")"
  grep -Fq "$message" "$test_tmp/err" || fail "$description is explained" "$(cat "$test_tmp/err")"
}

encrypt_root() {
  mkdir -p "$root/etc" "$root/var/lib/omarchy/provisioning" "$root/boot/omarchy" \
    "$root/dev/disk/by-uuid"
  printf 'root UUID=abcd-ef none luks\n' >"$root/etc/crypttab"
  printf 'linux /vmlinuz-linux-aurora rd.luks.name=abcd-ef=root root=/dev/mapper/root\ninitrd /initramfs-linux-aurora.img\n' \
    >"$root/boot/grub/grub.cfg"
  printf 'usr/lib/modules/%s/kernel/x.ko\nusr/lib/systemd/systemd-cryptsetup\nusr/lib/initcpio/hooks/sd-encrypt\n' "$kver" \
    >"$test_tmp/initramfs"
  printf 'HOOKS="base systemd autodetect modconf kms keyboard keymap block sd-encrypt filesystems fsck"\n' \
    >"$test_tmp/initramfs.analyze"
  printf 'format=1\nphase=finished\npartition=PART-1\nluks_uuid=abcd-ef\nowner_slot=1\nrecovery_slot=2\n' >"$root/boot/omarchy/encrypt.state"
  : >"$root/dev/disk/by-uuid/abcd-ef"
  TEST_LUKS_SLOT_COUNT=2
  TEST_LUKS_SLOTS="1 2"
  TEST_LUKS_TOKENS=""
}

# Unencrypted roots keep the existing expectations; missing install.conf is fine.
system
[[ ! -e $root/boot/efi/omarchy/install.conf ]] || fail "the fixture has no install.conf"
run_check
expect_pass "an unencrypted root with no install.conf"
pass "unencrypted roots are unchanged when install.conf is absent"

system
encrypt_root
run_check
expect_pass "an encrypted root after provisioning"
pass "encrypted roots expect rd.luks.name=, root=/dev/mapper/root, crypttab and sd-encrypt"

system
encrypt_root
printf 'linux /vmlinuz-linux-aurora root=/dev/mapper/root\ninitrd /initramfs-linux-aurora.img\n' >"$root/boot/grub/grub.cfg"
run_check
expect_fail "an encrypted root without rd.luks.name=" "does not set rd.luks.name="

system
encrypt_root
printf 'linux /vmlinuz-linux-aurora rd.luks.name=abcd-ef=root\ninitrd /initramfs-linux-aurora.img\n' >"$root/boot/grub/grub.cfg"
run_check
expect_fail "an encrypted root without mapper root" "does not set root=/dev/mapper/root"

system
encrypt_root
printf 'linux /vmlinuz-linux-aurora rd.luks.name=abcd-ef=root root=UUID=1111-2222\ninitrd /initramfs-linux-aurora.img\n' >"$root/boot/grub/grub.cfg"
TEST_MAPPER_UUID=1111-2222 run_check
expect_pass "an encrypted root named by the UUID of the filesystem inside the mapper (what update-grub emits)"

system
encrypt_root
printf "set root='hd0,gpt1'\nlinux /vmlinuz-linux-aurora rd.luks.name=abcd-ef=root root=UUID=1111-2222\ninitrd /initramfs-linux-aurora.img\n" >"$root/boot/grub/grub.cfg"
TEST_MAPPER_UUID=1111-2222 run_check
expect_pass "grub's own set root= line is not mistaken for the kernel's root="

system
encrypt_root
printf 'linux /vmlinuz-linux-aurora rd.luks.name=abcd-ef=root root=UUID=1111-2222\ninitrd /initramfs-linux-aurora.img\n' >"$root/boot/grub/grub.cfg"
TEST_MAPPER_UUID=3333-4444 run_check
expect_fail "an encrypted root whose root=UUID= names another filesystem" "does not name the filesystem on /dev/mapper/root"

system
encrypt_root
printf 'usr/lib/modules/%s/kernel/x.ko\nusr/bin/init\n' "$kver" >"$test_tmp/initramfs"
printf 'HOOKS="base systemd autodetect block filesystems fsck"\n' >"$test_tmp/initramfs.analyze"
run_check
expect_fail "an encrypted root without sd-encrypt" "does not contain sd-encrypt"

system
encrypt_root
printf 'linux /vmlinuz-linux-aurora rd.luks.name=abcd-ef=root rd.luks.key=abcd-ef=/omarchy/luks-key:UUID=4f4d5801-424f-4f54-8000-000000000001 root=/dev/mapper/root\ninitrd /initramfs-linux-aurora.img\n' \
  >"$root/boot/grub/grub.cfg"
run_check
expect_fail "rd.luks.key= after provisioning" "still has rd.luks.key= after provisioning"

system
encrypt_root
printf 'throwaway' >"$root/boot/omarchy/luks-key"
run_check
expect_fail "luks-key after provisioning" "luks-key still exists after provisioning"

system
encrypt_root
TEST_LUKS_SLOT_COUNT=3
TEST_LUKS_SLOTS="0 1 2"
run_check
expect_fail "throwaway keyslot after provisioning" "throwaway LUKS keyslot still present after provisioning"

system
encrypt_root
TEST_LUKS_SLOTS="0 1"
run_check
expect_fail "wrong slot numbers after provisioning" "does not contain the recorded owner and recovery slots"

# luksDump lists tokens the way it lists keyslots. A TPM2 and a keyring token on
# the owner and recovery slots are not leftover keyslots, and a keyring token
# numbered like a missing recovery slot does not stand in for it.
system
encrypt_root
TEST_LUKS_TOKENS="0:systemd-tpm2:1 1:luks2-keyring:2"
run_check
expect_pass "owner and recovery slots beside TPM2 and keyring tokens"

system
encrypt_root
TEST_LUKS_SLOTS="1"
TEST_LUKS_TOKENS="2:luks2-keyring:1"
run_check
expect_fail "a keyring token numbered like the missing recovery slot" "(1 keyslots, expected 2)"
pass "only luksDump's keyslot section counts as keyslots, whatever tokens are enrolled"

system
encrypt_root
printf 'linux /vmlinuz-linux-aurora rd.luks.name=other-uuid=root root=/dev/mapper/root\ninitrd /initramfs-linux-aurora.img\n' \
  >"$root/boot/grub/grub.cfg"
run_check
expect_fail "rd.luks.name UUID mismatch" "rd.luks.name= UUID does not match crypttab"

system
encrypt_root
rm -f "$root/boot/omarchy/encrypt.state"
run_check
expect_fail "missing encrypt.state after provisioning" "encrypt.state is missing after provisioning"

system
encrypt_root
printf 'format=1\nphase=encrypted\npartition=PART-1\nluks_uuid=abcd-ef\n' >"$root/boot/omarchy/encrypt.state"
run_check
expect_fail "encrypt.state not finished after provisioning" "encrypt.state is not phase=finished after provisioning"

system
encrypt_root
printf 'linux /vmlinuz-linux-aurora rd.luks.name=abcd-ef=root rd.luks.key=abcd-ef=/omarchy/luks-key:UUID=4f4d5801-424f-4f54-8000-000000000001 root=/dev/mapper/root\ninitrd /initramfs-linux-aurora.img\n' \
  >"$root/boot/grub/grub.cfg"
mkdir -p "$root/var/lib/omarchy/mac-first-boot"
touch "$root/var/lib/omarchy/mac-first-boot/pending"
printf 'throwaway' >"$root/boot/omarchy/luks-key"
TEST_LUKS_SLOT_COUNT=3
printf 'format=1\nphase=encrypted\npartition=PART-1\nluks_uuid=abcd-ef\n' >"$root/boot/omarchy/encrypt.state"
run_check
expect_pass "rd.luks.key= during the first-boot window"
pass "boot-check accepts the throwaway keyfile only while first-boot markers remain"

system
encrypt_root
printf 'usr/lib/modules/%s/kernel/x.ko\nusr/lib/systemd/systemd-cryptsetup\n' "$kver" >"$test_tmp/initramfs"
printf 'HOOKS="base systemd autodetect block filesystems fsck"\n' >"$test_tmp/initramfs.analyze"
run_check
expect_fail "systemd-cryptsetup without sd-encrypt" "does not contain sd-encrypt"

system
encrypt_root
printf 'usr/lib/modules/%s/kernel/x.ko\nusr/bin/init\n' "$kver" >"$test_tmp/initramfs"
printf 'HOOKS="base systemd autodetect modconf kms keyboard keymap block filesystems fsck"\n' \
  >"$test_tmp/initramfs.analyze"
mkdir -p "$root/etc"
printf 'HOOKS=(base systemd autodetect modconf kms keyboard keymap block sd-encrypt filesystems fsck)\n' \
  >"$root/etc/mkinitcpio.conf"
run_check
expect_fail "sd-encrypt only in mkinitcpio.conf" "does not contain sd-encrypt"
pass "boot-check requires sd-encrypt in the built initramfs"

system
mkdir -p "$root/etc"
printf '/dev/mapper/root / btrfs defaults 0 0\n' >"$root/etc/fstab"
run_check
expect_fail "mapper root without crypttab" "encrypted root has no crypttab"

system
mkdir -p "$root/etc"
printf '/dev/nvme0n1p5 / btrfs defaults 0 0\n' >"$root/etc/fstab"
printf '/dev/nvme0n1p5 btrfs\n/dev/nvme0n1p4 crypto_LUKS\n' >"$test_tmp/lsblk"
TEST_LSBLK="$test_tmp/lsblk" run_check
expect_fail "crypto_LUKS parent without crypttab" "encrypted root has no crypttab"
pass "a mapper or LUKS root without crypttab is a failure"

# The disk passphrase prompt types with the layout the boot image carries.
initrd_tree="$test_tmp/initrd-tree"
# What sd-vconsole, the busybox keymap hook and the plymouth hook put next to
# vconsole.conf: the console tools, the KEYMAP file, keymap.bin and the XKB
# symbols of each layout.
initrd_carries() {
  local setting keymap="" layouts="" layout
  rm -rf "$initrd_tree"
  mkdir -p "$initrd_tree/etc"
  (( $# == 0 )) || printf '%s\n' "$@" >"$initrd_tree/etc/vconsole.conf"
  mkdir -p "$initrd_tree/usr/lib/systemd" "$initrd_tree/usr/bin" "$initrd_tree/usr/share/kbd/keymaps/i386/qwerty" \
    "$initrd_tree/usr/share/X11/xkb/symbols"
  : >"$initrd_tree/usr/lib/systemd/systemd-vconsole-setup"
  : >"$initrd_tree/usr/bin/loadkeys"
  : >"$initrd_tree/usr/bin/plymouthd"
  : >"$initrd_tree/keymap.bin"
  for setting; do
    case $setting in
      KEYMAP=*) keymap=${setting#KEYMAP=} ;;
      XKBLAYOUT=*) layouts=${setting#XKBLAYOUT=} ;;
    esac
  done
  case $keymap in
    "" | /*) ;;
    */*)
      mkdir -p "$(dirname "$initrd_tree/usr/share/kbd/keymaps/$keymap")"
      : >"$initrd_tree/usr/share/kbd/keymaps/$keymap.map.gz"
      ;;
    *) : >"$initrd_tree/usr/share/kbd/keymaps/i386/qwerty/$keymap.map.gz" ;;
  esac
  for layout in ${layouts//,/ }; do
    : >"$initrd_tree/usr/share/X11/xkb/symbols/$layout"
  done
}
host_layout() {
  mkdir -p "$root/etc"
  printf '%s\n' "$@" >"$root/etc/vconsole.conf"
}
danish=(KEYMAP=dk-latin1 XKBLAYOUT=dk XKBMODEL=pc105 XKBOPTIONS=terminate:ctrl_alt_bksp)

system
encrypt_root
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
mkdir -p "$test_tmp/tmpdir"
TMPDIR=$test_tmp/tmpdir TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "an encrypted GRUB Mac whose initramfs carries the Danish vconsole.conf"
grep -Fq "lsinitcpio -x $root/boot/initramfs-linux-aurora.img" "$calls" ||
  fail "the GRUB initramfs is the image checked for the layout" "$(cat "$calls")"
[[ -z $(ls -A "$test_tmp/tmpdir") ]] || fail "the extracted image is removed" "$(find "$test_tmp/tmpdir")"

system
encrypt_root
host_layout "${danish[@]}"
initrd_carries KEYMAP=us XKBLAYOUT=us
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "an initramfs built before the layout changed" "does not carry the keyboard layout of /etc/vconsole.conf (KEYMAP=dk-latin1 XKBLAYOUT=dk)"
grep -Fq "sudo /usr/bin/mkinitcpio -P && sudo omarchy-mac-boot-update" "$test_tmp/err" ||
  fail "a GRUB Mac is told to rebuild with mkinitcpio and omarchy-mac-boot-update" "$(cat "$test_tmp/err")"
TEST_BOOT_CHAIN=1 TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "an initramfs built before the layout changed, checked for the next boot" "does not carry the keyboard layout of /etc/vconsole.conf"

system
encrypt_root
host_layout "${danish[@]}"
initrd_carries
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "an initramfs without vconsole.conf" "does not carry the keyboard layout of /etc/vconsole.conf"

system
encrypt_root
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
rm "$initrd_tree/usr/share/kbd/keymaps/i386/qwerty/dk-latin1.map.gz"
: >"$initrd_tree/usr/share/kbd/keymaps/i386/qwerty/dk.map.gz"
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "an image without the KEYMAP file" "carries /etc/vconsole.conf but not what loads it at the disk passphrase prompt (missing the dk-latin1 keymap)"
TEST_BOOT_CHAIN=1 TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "an image without the KEYMAP file, checked for the next boot" "missing the dk-latin1 keymap"

system
encrypt_root
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
rm "$initrd_tree/usr/lib/systemd/systemd-vconsole-setup"
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "an image without sd-vconsole" "missing /usr/lib/systemd/systemd-vconsole-setup"
grep -Fq "sudo /usr/bin/mkinitcpio -P && sudo omarchy-mac-boot-update" "$test_tmp/err" ||
  fail "a missing loader names the rebuild" "$(cat "$test_tmp/err")"

system
encrypt_root
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
rm "$initrd_tree/usr/share/X11/xkb/symbols/dk"
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a Plymouth image without the XKB symbols" "missing the XKB symbols for dk"

system
encrypt_root
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
rm "$initrd_tree/usr/share/X11/xkb/symbols/dk" "$initrd_tree/usr/bin/plymouthd"
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "an image without Plymouth, which needs no XKB symbols"

system
encrypt_root
host_layout KEYMAP=/usr/local/share/kbd/my.map XKBLAYOUT=dk
initrd_carries KEYMAP=us XKBLAYOUT=dk
sed -i 's|^KEYMAP=.*|KEYMAP=/usr/local/share/kbd/my.map|' "$initrd_tree/etc/vconsole.conf"
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "an image without an absolute KEYMAP" "missing /usr/local/share/kbd/my.map"
mkdir -p "$initrd_tree/usr/local/share/kbd"
: >"$initrd_tree/usr/local/share/kbd/my.map"
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "an image that carries the absolute KEYMAP"

system
encrypt_root
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
mv "$initrd_tree/usr/share/kbd/keymaps/i386/qwerty/dk-latin1.map.gz" "$initrd_tree/usr/share/kbd/keymaps/i386/qwerty/dk-latin1.map.bak"
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a keymap file with a suffix sd-vconsole does not load" "missing the dk-latin1 keymap"

system
encrypt_root
host_layout KEYMAP=i386/qwerty/dk-latin1 XKBLAYOUT=dk
initrd_carries KEYMAP=i386/qwerty/dk-latin1 XKBLAYOUT=dk
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "a KEYMAP named with its directory"

system
encrypt_root
host_layout XKBLAYOUT=dk,us
initrd_carries XKBLAYOUT=dk,us
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "an XKB-only layout, whose console keeps the US map"
rm "$initrd_tree/usr/share/X11/xkb/symbols/us"
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a second XKB layout without its symbols" "missing the XKB symbols for us"
pass "the image must carry what loads the layout, not only vconsole.conf"

# A Mac whose busybox init unlocks the root through cryptdevice= loads its
# console keymap from the keymap hook's keymap.bin, not from sd-vconsole, and
# has no crypttab.
busybox_root() {
  rm -f "$root/etc/crypttab"
  printf '/dev/mapper/root / btrfs subvol=@ 0 0\n' >"$root/etc/fstab"
  printf 'linux /vmlinuz-linux-aurora root=UUID=x rw rootflags=subvol=@ cryptdevice=UUID=abcd-ef:root\ninitrd /initramfs-linux-aurora.img\n' \
    >"$root/boot/grub/grub.cfg"
  printf 'usr/lib/modules/%s/kernel/x.ko\nusr/bin/init\ninit_functions\nhooks/encrypt\nhooks/keymap\nkeymap.bin\n' "$kver" >"$test_tmp/initramfs"
}
system
encrypt_root
busybox_root
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
rm "$initrd_tree/usr/lib/systemd/systemd-vconsole-setup" "$initrd_tree/usr/share/kbd/keymaps/i386/qwerty/dk-latin1.map.gz"
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "a busybox image, which has no sd-vconsole"
TEST_BOOT_CHAIN=1 TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "a busybox image, checked for the next boot"
rm "$initrd_tree/keymap.bin"
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a busybox image without the keymap hook's keymap.bin" "missing the keymap hook's keymap.bin"
TEST_BOOT_CHAIN=1 TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a busybox image without keymap.bin, checked for the next boot" "missing the keymap hook's keymap.bin"
initrd_carries KEYMAP=us XKBLAYOUT=us
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a busybox image built before the layout changed" "/boot/initramfs-linux-aurora.img does not carry the keyboard layout of /etc/vconsole.conf"
host_layout XKBLAYOUT=dk
initrd_carries XKBLAYOUT=dk
rm "$initrd_tree/keymap.bin"
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "a busybox image for an XKB-only layout, whose console keeps the US map"
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
rm "$initrd_tree/usr/share/X11/xkb/symbols/dk"
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a busybox Plymouth image without the XKB symbols" "missing the XKB symbols for dk"
pass "a busybox encrypt Mac without crypttab is checked for vconsole.conf, keymap.bin and the XKB symbols"

system
encrypt_root
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
printf 'loadkeys: Unable to open file: dk-latin1: No such file or directory\n/usr/bin/loadkeys failed with exit status 1.\nsystemd-vconsole-setup.service: Failed with result '"'"'exit-code'"'"'.\n' \
  >"$test_tmp/journal"
TEST_INITRD_TREE=$initrd_tree TEST_JOURNAL="$test_tmp/journal" OMARCHY_BOOT_CHECK_LIVE_JOURNAL=1 run_check
expect_pass "a failed console setup this boot is a warning, not a failure"
grep -Fq "warning: the console keyboard setup failed during this boot (/usr/bin/loadkeys failed with exit status 1.)" "$test_tmp/err" ||
  fail "a failed console setup this boot is reported" "$(cat "$test_tmp/err")"
grep -Fq "journalctl -b --no-pager -o cat -u systemd-vconsole-setup.service" "$calls" ||
  fail "the check reads this boot's systemd-vconsole-setup journal" "$(cat "$calls")"
printf 'Configuration of first virtual console was skipped, ignoring remaining ones.\n' >"$test_tmp/journal"
TEST_INITRD_TREE=$initrd_tree TEST_JOURNAL="$test_tmp/journal" OMARCHY_BOOT_CHECK_LIVE_JOURNAL=1 run_check
expect_pass "a console setup that only skipped the font"
! grep -Fq "warning" "$test_tmp/err" || fail "a skipped font is not a keyboard failure" "$(cat "$test_tmp/err")"
TEST_INITRD_TREE=$initrd_tree TEST_JOURNAL="$test_tmp/journal" run_check
! grep -Fq "journalctl" "$calls" || fail "a check of another root does not read this machine's journal" "$(cat "$calls")"
pass "this boot's failed console keyboard setup is reported as a warning"

system
encrypt_root
host_layout '# edited by hand' "${danish[@]}" FONT=ter-132n
initrd_carries "${danish[@]}"
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "an image whose vconsole.conf differs only in comments and font"

system
encrypt_root
host_layout KEYMAP=de-latin1 XKBLAYOUT=de XKBVARIANT=nodeadkeys
initrd_carries KEYMAP=de-latin1 XKBLAYOUT=de
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "an image missing the XKB variant" "does not carry the keyboard layout"
pass "an encrypted Mac with a Latin non-US layout needs its keyboard settings in the initramfs"

system
encrypt_root
host_layout KEYMAP=us XKBLAYOUT=us
initrd_carries
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "a US layout"
! grep -Fq 'lsinitcpio -x' "$calls" || fail "a US layout extracts nothing" "$(cat "$calls")"
system
encrypt_root
host_layout KEYMAP=ru XKBLAYOUT=ru,us
initrd_carries
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "a non-Latin layout, which stays out of the initramfs on purpose"
! grep -Fq 'lsinitcpio -x' "$calls" || fail "a non-Latin layout extracts nothing" "$(cat "$calls")"
system
host_layout "${danish[@]}"
initrd_carries
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "an unencrypted root, which has no passphrase prompt"
! grep -Fq 'lsinitcpio -x' "$calls" || fail "an unencrypted Mac extracts nothing" "$(cat "$calls")"
pass "US, non-Latin and unencrypted Macs are not checked for the layout"

# A Limine Mac boots the UKI, whose .initrd is the image checked.
limine_mac() {
  local esp_path=${1:-/boot/efi} uki
  mkdir -p "$root/var/lib/omarchy" "$root/etc/default" "$root/usr/share/limine" "$root$esp_path/EFI/Linux" "$root$esp_path/EFI/BOOT"
  : >"$root/var/lib/omarchy/limine.enabled"
  printf 'ESP_PATH="%s"\nENABLE_UKI=yes\n' "$esp_path" >"$root/etc/default/limine"
  printf 'limine\n' >"$root/usr/share/limine/BOOTAA64.EFI"
  cp "$root/usr/share/limine/BOOTAA64.EFI" "$root$esp_path/EFI/BOOT/BOOTAA64.EFI"
  uki=$root$esp_path/EFI/Linux/omarchy_linux-aurora.efi
  { cat "$modules/vmlinuz"; printf 'initrd\n'; } >"$uki"
  printf '/+Omarchy\n  //linux-aurora\n    protocol: efi\n    path: boot():/EFI/Linux/omarchy_linux-aurora.efi#%s\n    cmdline: root=UUID=1111-2222 rw rootflags=subvol=@ rd.luks.name=abcd-ef=root\n' \
    "$(b2sum "$uki" | cut -d' ' -f1)" >"$root$esp_path/limine.conf"
  [[ $esp_path == /boot/efi ]] || mv "$esp/m1n1" "$root$esp_path/m1n1"
}

system
encrypt_root
limine_mac
host_layout "${danish[@]}"
initrd_carries "${danish[@]}"
TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "an encrypted Limine Mac whose UKI carries the Danish vconsole.conf"
grep -Fq "objcopy -O binary --only-section=.initrd $esp/EFI/Linux/omarchy_linux-aurora.efi" "$calls" ||
  fail "a Limine Mac checks the initramfs inside the UKI" "$(cat "$calls")"
TEST_BOOT_CHAIN=1 TEST_INITRD_TREE=$initrd_tree run_check
expect_pass "an encrypted Limine Mac whose UKI carries the layout, checked for the next boot"

system
encrypt_root
limine_mac
host_layout "${danish[@]}"
initrd_carries KEYMAP=us XKBLAYOUT=us
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a UKI built before the layout changed" "the initramfs inside /boot/efi/EFI/Linux/omarchy_linux-aurora.efi does not carry the keyboard layout"
grep -Fq "rebuild the boot image with 'sudo omarchy-mac-boot-update'" "$test_tmp/err" ||
  fail "a Limine Mac is told to rebuild with omarchy-mac-boot-update" "$(cat "$test_tmp/err")"
TEST_BOOT_CHAIN=1 TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a UKI built before the layout changed, checked for the next boot" "does not carry the keyboard layout"

system
encrypt_root
limine_mac /boot
host_layout "${danish[@]}"
initrd_carries KEYMAP=us XKBLAYOUT=us
TEST_INITRD_TREE=$initrd_tree run_check
expect_fail "a UKI on an ESP mounted at /boot" "the initramfs inside /boot/EFI/Linux/omarchy_linux-aurora.efi does not carry the keyboard layout"
pass "a Limine Mac checks the layout inside the UKI it boots"
