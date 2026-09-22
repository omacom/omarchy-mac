#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

require_command gzip
require_command realpath

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
if [[ "$1" == "-a" && -f "$2" ]]; then
  cat "${TEST_INITRAMFS_ANALYZE:-$TEST_INITRAMFS_LIST.analyze}"
  exit 0
fi
[[ "$1" == "-l" && -f "$2" ]] || exit 1
cat "$TEST_INITRAMFS_LIST"
SH
cat >"$stub_bin/cryptsetup" <<'SH'
#!/bin/bash
case "$1" in
  luksDump)
    if [[ -n ${TEST_LUKS_SLOTS:-} ]]; then
      for slot in $TEST_LUKS_SLOTS; do
        printf '  %s: luks2\n' "$slot"
      done
      exit 0
    fi
    slots=${TEST_LUKS_SLOT_COUNT:-2}
    i=0
    while (( i < slots )); do
      printf '  %s: luks2\n' "$i"
      (( ++i ))
    done
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
    TEST_INITRAMFS_ANALYZE="${TEST_INITRAMFS_ANALYZE:-$test_tmp/initramfs.analyze}" \
    TEST_LSBLK="${TEST_LSBLK:-}" \
    TEST_MAPPER_UUID="${TEST_MAPPER_UUID:-}" \
    OMARCHY_BOOT_CHECK_ROOT="$root" \
    OMARCHY_BOOT_CHECK_UNAME="$kver" \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    bash "$check" linux-aurora >"$test_tmp/out" 2>"$test_tmp/err"
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

