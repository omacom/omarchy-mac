#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-mac-esp: the device tree's ESP where it is mounted whole, /boot/efi
# first; without the device tree's name, the FAT filesystem there.
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin=$test_tmp/bin
esp_node=$test_tmp/esp-partuuid
mounts=$test_tmp/mounts
mkdir -p "$stub_bin"

cat >"$stub_bin/findmnt" <<'SH'
#!/bin/bash
[[ "${*:1:5}" == "-n -r -o FSTYPE,FSROOT,PARTUUID --mountpoint" ]] || exit 1
awk -v target="$6" '$1 == target { print $2, $3, $4; found = 1 } END { exit !found }' "$TEST_MOUNTS"
SH
chmod +x "$stub_bin/findmnt"

find_esp() {
  OMARCHY_ESP_PARTUUID_FILE="$esp_node" TEST_MOUNTS="$mounts" PATH="$stub_bin:$PATH" bash "$ROOT/bin/omarchy-mac-esp" 2>"$test_tmp/err"
}

printf '5F2B0C3E-0002\0' >"$esp_node"
printf '/boot/efi vfat / 5f2b0c3e-0002\n/boot btrfs /@/boot x\n' >"$mounts"
[[ $(find_esp) == /boot/efi ]] || fail "the device tree's ESP at /boot/efi is found"
printf '/boot vfat / 5f2b0c3e-0002\n' >"$mounts"
[[ $(find_esp) == /boot ]] || fail "the device tree's ESP at /boot is found (an older install)"
printf '/boot/efi vfat / 11111111-0001\n/boot vfat / 5f2b0c3e-0002\n' >"$mounts"
[[ $(find_esp) == /boot ]] || fail "another FAT filesystem at /boot/efi is not the system ESP"
printf '/boot/efi vfat /EFI 5f2b0c3e-0002\n' >"$mounts"
! find_esp >/dev/null || fail "a bind of part of the ESP is not the ESP"
grep -Fq 'PARTUUID=5f2b0c3e-0002' "$test_tmp/err" || fail "the missing ESP is named"
printf '/boot/efi autofs / \n/boot/efi vfat / 5f2b0c3e-0002\n' >"$mounts"
[[ $(find_esp) == /boot/efi ]] || fail "an ESP mounted over its automount point is found"
rm -f "$esp_node"
printf '/boot vfat / 11111111-0001\n' >"$mounts"
[[ $(find_esp) == /boot ]] || fail "without a device tree name the FAT filesystem at /boot is the ESP"
printf '/boot ext4 / 11111111-0001\n' >"$mounts"
! find_esp >/dev/null || fail "an ext4 /boot is not an ESP"
pass "omarchy-mac-esp finds the system ESP at /boot/efi or /boot"
