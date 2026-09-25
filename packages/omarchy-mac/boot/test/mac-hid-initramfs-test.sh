#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
files=$ROOT/files
hid_conf=$files/etc/mkinitcpio.conf.d/92-omarchy-mac-hid.conf
install_hook=$files/etc/initcpio/install/omarchy-vendorfw
late_sh=$files/usr/lib/omarchy/initcpio/omarchy-vendorfw.sh
late_unit=$files/usr/lib/omarchy/initcpio/omarchy-vendorfw.service
early_sh=$files/usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.sh
early_unit=$files/usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.service
cryptsetup_dropin=$files/usr/lib/omarchy/initcpio/omarchy-vendorfw-cryptsetup.conf

fail() {
  echo "not ok - $1" >&2
  [[ $# -lt 2 ]] || printf '%s\n' "$2" >&2
  exit 1
}

[[ -f $hid_conf ]] || fail "92-omarchy-mac-hid.conf is in the package files tree"
[[ -f $install_hook ]] || fail "the omarchy-vendorfw install hook is in the package files tree"
[[ -f $late_sh ]] || fail "omarchy-vendorfw.sh is in the package files tree"
[[ -f $late_unit ]] || fail "the post-mount vendorfw unit is in the package files tree"
[[ -f $early_sh ]] || fail "omarchy-vendorfw-initrd.sh is in the package files tree"
[[ -f $early_unit ]] || fail "omarchy-vendorfw-initrd.service is in the package files tree"
[[ -f $cryptsetup_dropin ]] || fail "the systemd-cryptsetup@.service drop-in is in the package files tree"
[[ ! -e $files/usr/lib/omarchy/initcpio/omarchy-vendorfw-sysroot.service ]] ||
  fail "omarchy-vendorfw-sysroot.service must not ship"
# T3a may ship etc/systemd/system/omarchy-vendor-firmware.service in this
# files/ tree. That is a companion; this test does not forbid it.

grep -Fq 'After=sysroot.mount' "$late_unit" ||
  fail "the late unit still waits for sysroot.mount"
grep -Fq 'Before=cryptsetup-pre.target' "$early_unit" ||
  fail "the early unit is ordered Before=cryptsetup-pre.target"
grep -Fq 'dev-disk-by\x2duuid-4F4D\x2d5801.device' "$early_unit" ||
  fail "the early unit orders After/Wants the image ESP device"
grep -E '^After=' "$early_unit" | grep -Fq 'dev-disk-by\x2duuid-4F4D\x2d5801.device' ||
  fail "the early unit is After the ESP device unit"
grep -E '^Wants=' "$early_unit" | grep -Fq 'dev-disk-by\x2duuid-4F4D\x2d5801.device' ||
  fail "the early unit Wants the ESP device unit"
grep -Eq '^JobTimeoutSec=' "$early_unit" ||
  fail "the early unit sets JobTimeoutSec so a missing ESP cannot hang forever"
grep -Fq 'DefaultDependencies=no' "$early_unit" ||
  fail "the early unit sets DefaultDependencies=no"
grep -Fq 'WantedBy=initrd-root-device.target' "$early_unit" ||
  fail "the early unit is WantedBy initrd-root-device.target"
grep -E '^WantedBy=' "$early_unit" | grep -Fq 'sysinit.target' ||
  fail "the early unit is WantedBy sysinit.target"
if grep -Fq 'After=sysroot.mount' "$early_unit"; then
  fail "the early unit must not wait for sysroot.mount"
fi
grep -Fq 'omarchy-vendorfw-initrd.service' "$install_hook" ||
  fail "the combined hook installs omarchy-vendorfw-initrd.service"
grep -Fq 'omarchy-vendorfw.service' "$install_hook" ||
  fail "the combined hook still installs the post-mount unit"
grep -Fq 'initrd-root-device.target.wants/omarchy-vendorfw-initrd.service' "$install_hook" ||
  fail "the install hook links the early unit into initrd-root-device.target.wants"
grep -Fq 'sysinit.target.wants/omarchy-vendorfw-initrd.service' "$install_hook" ||
  fail "the install hook links the early unit into sysinit.target.wants"
grep -Fq 'systemd-cryptsetup@.service.d/omarchy-vendorfw-initrd.conf' "$install_hook" ||
  fail "the install hook installs the systemd-cryptsetup@.service drop-in"
grep -Fq 'Wants=omarchy-vendorfw-initrd.service' "$cryptsetup_dropin" ||
  fail "the cryptsetup drop-in Wants the early vendorfw unit"
grep -Fq 'After=omarchy-vendorfw-initrd.service' "$cryptsetup_dropin" ||
  fail "the cryptsetup drop-in is After the early vendorfw unit"
if grep -E 'add_dir[[:space:]]+/vendorfw' "$install_hook"; then
  fail "the install hook must not pre-create /vendorfw or /vendorfw/apple"
fi
grep -Fq '4F4D-5801' "$early_sh" ||
  fail "the early helper discovers the image ESP UUID"
grep -Fq 'vendorfw/firmware.cpio' "$early_sh" ||
  fail "the early helper unpacks ESP vendorfw/firmware.cpio"
grep -Fq '/run/omarchy-vendorfw-initrd.status' "$early_sh" ||
  fail "the early helper records /run/omarchy-vendorfw-initrd.status when firmware is missing"
grep -Fq 'missing' "$early_sh" ||
  fail "the early helper records status=missing"
grep -Fq 'menci/archlinuxarm:latest' "${BASH_SOURCE[0]}" ||
  fail "the container image is Arch Linux ARM"
if grep -Eq '[|][|] image=' "${BASH_SOURCE[0]}"; then
  fail "the test must not silently fall back to another container image"
fi
grep -Fq -- '--privileged' "${BASH_SOURCE[0]}" ||
  fail "the container run is privileged"
grep -Fq 'PARTUUID' "$late_sh" ||
  fail "the late script still mounts the ESP by PARTUUID"
grep -Fq 'apple/tpmtfw-' "$hid_conf" ||
  fail "the HID drop-in documents the MTP firmware path"
grep -Fq 'dockchannel-hid' "$hid_conf" ||
  fail "the HID drop-in names dockchannel-hid"
if grep -v '^#' "$hid_conf" | grep -Eq 'apple-mtp|apple_mtp'; then
  fail "linux-aurora has no apple-mtp module to name"
fi
echo 'ok - original late vendorfw preserved; distinct omarchy-vendorfw-initrd predecessor'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub=$tmp/bin
mkdir -p "$stub" "$tmp/modinfo"

cat >"$stub/modinfo" <<'SH'
#!/bin/sh
module=
want_filename=0
while [ $# -gt 0 ]; do
  case $1 in
    -F)
      [ "$2" = filename ] && want_filename=1
      shift 2
      ;;
    -k) shift 2 ;;
    *) module=$1; shift ;;
  esac
done
[ -n "$MODINFO_DIR" ] && [ -f "$MODINFO_DIR/$module" ] || exit 1
read -r filename <"$MODINFO_DIR/$module" || exit 1
if [ "$want_filename" -eq 1 ]; then
  printf '%s\n' "$filename"
  exit 0
fi
printf 'filename:%s\n' "$filename"
SH
chmod +x "$stub/modinfo"

write_modinfo() {
  rm -rf "$tmp/modinfo"
  mkdir -p "$tmp/modinfo"
  local spec name path
  for spec in "$@"; do
    name=${spec%%=*}
    path=${spec#*=}
    printf '%s\n' "$path" >"$tmp/modinfo/$name"
  done
}

source_hid() {
  write_modinfo "$@"
  export MODINFO_DIR=$tmp/modinfo
  PATH="$stub:$PATH" bash -c '
    MODULES=(btrfs)
    FILES=()
    source "$1"
    status=$?
    printf "%s\n" "$status" "${MODULES[*]}" "$(declare -p _omarchy_mac_hid_module 2>/dev/null || echo unset)"
  ' bash "$hid_conf"
}

mapfile -t sourced < <(source_hid \
  hid_apple=/lib/modules/x/hid-apple.ko \
  hid_magicmouse=/lib/modules/x/hid-magicmouse.ko \
  dockchannel-hid=/lib/modules/x/dockchannel-hid.ko \
  usbhid=/lib/modules/x/usbhid.ko \
  thunderbolt=/lib/modules/x/thunderbolt.ko \
  thunderbolt_apple=/lib/modules/x/thunderbolt_apple.ko \
  spi-hid-apple-of='(builtin)')
[[ ${sourced[0]} == 0 ]] || fail "the drop-in sources cleanly" "status ${sourced[0]}"
[[ ${sourced[1]} == "btrfs hid_apple hid_magicmouse dockchannel-hid usbhid thunderbolt thunderbolt_apple" ]] ||
  fail "modular HID drivers, thunderbolt and thunderbolt_apple (dock keyboards, omarchy-mx-mac#86) are early-loaded; built-in SPI HID is left out" "MODULES=(${sourced[1]})"
[[ ${sourced[2]} == unset ]] || fail "the drop-in leaves no variable behind" "${sourced[2]}"
echo 'ok - modular HID drivers and thunderbolt are early-loaded and built-in SPI HID is skipped'

mapfile -t sourced < <(source_hid hid_apple=/lib/modules/x/hid-apple.ko)
[[ ${sourced[0]} == 0 ]] || fail "a kernel missing some drivers still sources cleanly" "status ${sourced[0]}"
[[ ${sourced[1]} == "btrfs hid_apple" ]] ||
  fail "a driver the kernel does not build is left out" "MODULES=(${sourced[1]})"
echo 'ok - a driver the kernel does not build is left out'

if [[ ${OMARCHY_DISPOSABLE_BOOT_TESTS:-0} != "1" && ${IN_OMARCHY_MAC_HID_TEST:-0} != "1" ]]; then
  echo 'ok - source checks passed; disposable initramfs/block tests not run (OMARCHY_DISPOSABLE_BOOT_TESTS=1 opts in)'
  exit 0
fi

if [[ ${IN_OMARCHY_MAC_HID_TEST:-} != 1 ]]; then
  command -v docker >/dev/null 2>&1 ||
    fail "docker is required to generate the initramfs in an Arch container"
  image=menci/archlinuxarm:latest
  exec docker run --rm --privileged --platform linux/arm64 \
    -e IN_OMARCHY_MAC_HID_TEST=1 \
    -v "$ROOT:/repo" \
    -w /repo \
    "$image" \
    bash /repo/test/mac-hid-initramfs-test.sh
fi

[[ $(uname -m) == aarch64 ]] ||
  fail "the container architecture must be aarch64 (got $(uname -m)); never fall back to archlinux:base"

command -v pacman >/dev/null 2>&1 || fail "the Arch container has pacman"
pacman --disable-sandbox -Sy --noconfirm --needed \
  mkinitcpio cpio binutils systemd cryptsetup kmod util-linux >/dev/null
command -v mkinitcpio >/dev/null 2>&1 || fail "mkinitcpio is installed in the container"
command -v lsinitcpio >/dev/null 2>&1 || fail "lsinitcpio is installed in the container"
command -v systemd-analyze >/dev/null 2>&1 || fail "systemd-analyze is installed in the container"

asahi_note=stub
if pacman --disable-sandbox -S --noconfirm --needed asahi-scripts >/dev/null 2>&1 &&
  [[ -f /usr/lib/initcpio/install/asahi || -f /etc/initcpio/install/asahi ]]; then
  asahi_note=asahi-scripts
else
  # Same install semantics as AsahiLinux/asahi-scripts initcpio/install/asahi:
  # optional Apple platform modules, /lib/firmware, and the vendor symlink.
  # The asahi runtime hook is not used under systemd initrd.
  install -Dm755 /dev/stdin /usr/lib/initcpio/install/asahi <<'HOOK'
#!/bin/bash
# SPDX-License-Identifier: MIT
# Stub: asahi-scripts is not in this container. Mirrors
# https://github.com/AsahiLinux/asahi-scripts/blob/main/initcpio/install/asahi

build() {
    add_module apple-mailbox?
    add_module nvme-apple?
    add_module pinctrl-apple-gpio?
    map add_module macsmc? macsmc-rtkit?
    map add_module i2c-pasemi-platform? tps6598x? apple-dart? dwc3? dwc3-of-simple? \
      nvmem-apple-efuses? phy-apple-atc? xhci-plat-hcd? xhci-pci? pcie-apple? gpio_macsmc?
    map add_module spi-apple? spi-hid-apple? spi-hid-apple-of?
    map add_module rtc-macsmc? simple-mfd-spmi? spmi-apple-controller? \
      nvmem_spmi_mfd?
    map add_module apple-dockchannel? dockchannel-hid? apple-rtkit-helper?
    add_dir /lib/firmware
    add_symlink /lib/firmware/vendor /vendorfw
}

help() {
    cat <<HELPEOF
Asahi install-hook stub (container has no asahi-scripts). Same install
semantics as the upstream asahi hook; runtime early/late hooks omitted
because they do not run under the systemd initrd.
HELPEOF
}
HOOK
fi
echo "ok - asahi hook is $asahi_note"

kver=$(uname -r)
moddir=/lib/modules/$kver/kernel/extra
mkdir -p "$moddir" /lib/modules/"$kver"/kernel/drivers/hid
touch "/lib/modules/$kver/modules.order" "/lib/modules/$kver/modules.builtin" \
  "/lib/modules/$kver/modules.builtin.modinfo"
elf=$(find /usr/lib -type f \( -name 'libgmp.so*' -o -name 'libc.so*' \) 2>/dev/null | head -1)
[[ -n $elf ]] || fail "the container has an ELF to mint fake .ko files from"

mint_ko() {
  local module=$1
  local hyphen=${module//_/-}
  local dest=/lib/modules/$kver/kernel/extra/${hyphen}.ko
  [[ -e $dest ]] && return 0
  printf 'name=%s\0vermagic=%s SMP preempt mod_unload\0' "${module//-/_}" "$kver" >"$tmp/modinfo.$hyphen"
  objcopy --add-section ".modinfo=$tmp/modinfo.$hyphen" \
    --set-section-flags .modinfo=contents,alloc,readonly,data \
    "$elf" "$dest" 2>/dev/null || cp "$elf" "$dest"
}

for module in hid-apple hid-magicmouse dockchannel-hid usbhid thunderbolt thunderbolt_apple \
  crypto_lzo crypto_lz4 dm_crypt dm_integrity; do
  mint_ko "$module"
done
# HID drop-in looks under drivers/hid as well as extra/.
for module in hid-apple hid-magicmouse dockchannel-hid usbhid; do
  ln -sfn "../../extra/${module}.ko" "/lib/modules/$kver/kernel/drivers/hid/${module}.ko"
done
depmod "$kver" >/dev/null 2>&1 || true
modinfo -k "$kver" -F filename hid_apple | grep -q '^/' ||
  fail "fake hid_apple is visible to modinfo"
modinfo -k "$kver" -F filename dockchannel-hid | grep -q '^/' ||
  fail "fake dockchannel-hid is visible to modinfo"

install -Dm755 "$late_sh" /usr/lib/omarchy/initcpio/omarchy-vendorfw.sh
install -Dm755 "$early_sh" /usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.sh
install -Dm644 "$late_unit" /usr/lib/omarchy/initcpio/omarchy-vendorfw.service
install -Dm644 "$early_unit" /usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.service
install -Dm644 "$cryptsetup_dropin" /usr/lib/omarchy/initcpio/omarchy-vendorfw-cryptsetup.conf
install -Dm755 "$install_hook" /usr/lib/initcpio/install/omarchy-vendorfw
install -Dm644 "$hid_conf" /etc/mkinitcpio.conf.d/92-omarchy-mac-hid.conf
install -Dm644 "$files/etc/mkinitcpio.conf.d/90-omarchy-mac.conf" /etc/mkinitcpio.conf.d/90-omarchy-mac.conf

printf 'root UUID=00000000-0000-0000-0000-000000000001 none luks\n' >/etc/crypttab

cat >/etc/mkinitcpio.conf <<'CONF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd modconf block sd-encrypt filesystems)
COMPRESSION=gzip
CONF

img=$tmp/initramfs.img
mkinitcpio_log=$tmp/mkinitcpio.log
mkinitcpio_ok=0
for _mkinitcpio_try in 1 2 3 4 5 6 7 8; do
  if mkinitcpio -k "$kver" -g "$img" >"$mkinitcpio_log" 2>&1; then
    mkinitcpio_ok=1
    break
  fi
  mapfile -t missing < <(sed -n "s/.*module not found: '\\([^']*\\)'.*/\\1/p" "$mkinitcpio_log" | sort -u)
  (( ${#missing[@]} > 0 )) || break
  for module in "${missing[@]}"; do
    mint_ko "$module"
  done
  depmod "$kver" >/dev/null 2>&1 || true
done
if (( mkinitcpio_ok != 1 )); then
  fail "mkinitcpio failed" "$(cat "$mkinitcpio_log")"
fi
[[ -s $img ]] || fail "mkinitcpio produced an initramfs" "$(cat "$mkinitcpio_log")"
echo 'ok - mkinitcpio built a systemd+asahi+sd-encrypt+omarchy-vendorfw initramfs'

list=$tmp/lsinitcpio
lsinitcpio "$img" >"$list"
grep -Eq 'hid-apple|hid_apple' "$list" || fail "lsinitcpio lists hid_apple" "$(cat "$list")"
grep -Eq 'hid-magicmouse|hid_magicmouse' "$list" || fail "lsinitcpio lists hid_magicmouse" "$(cat "$list")"
grep -Eq 'dockchannel-hid|dockchannel_hid' "$list" || fail "lsinitcpio lists dockchannel-hid" "$(cat "$list")"
grep -Eq 'usbhid' "$list" || fail "lsinitcpio lists usbhid" "$(cat "$list")"
grep -Eq '(^|/)thunderbolt\.ko' "$list" || fail "lsinitcpio lists thunderbolt (dock keyboards, omarchy-mx-mac#86)" "$(cat "$list")"
grep -Eq '(^|/)thunderbolt[-_]apple\.ko' "$list" || fail "lsinitcpio lists thunderbolt_apple, the Apple Silicon USB4 host router" "$(cat "$list")"
grep -Fq 'omarchy-vendorfw.sh' "$list" || fail "lsinitcpio lists the late vendorfw script"
grep -Fq 'omarchy-vendorfw-initrd.sh' "$list" || fail "lsinitcpio lists the early vendorfw helper"
grep -Fq 'omarchy-vendorfw.service' "$list" || fail "lsinitcpio lists the late vendorfw unit"
grep -Fq 'omarchy-vendorfw-initrd.service' "$list" || fail "lsinitcpio lists the early vendorfw unit"
grep -Fq 'cryptsetup-pre.target.wants/omarchy-vendorfw-initrd.service' "$list" ||
  fail "lsinitcpio lists the cryptsetup-pre.target wants symlink" "$(cat "$list")"
grep -Fq 'initrd-root-device.target.wants/omarchy-vendorfw-initrd.service' "$list" ||
  fail "lsinitcpio lists the initrd-root-device.target wants symlink" "$(cat "$list")"
grep -Fq 'sysinit.target.wants/omarchy-vendorfw-initrd.service' "$list" ||
  fail "lsinitcpio lists the sysinit.target wants symlink" "$(cat "$list")"
grep -Fq 'systemd-cryptsetup@.service.d/omarchy-vendorfw-initrd.conf' "$list" ||
  fail "lsinitcpio lists the systemd-cryptsetup@.service drop-in" "$(cat "$list")"
grep -Fq 'initrd.target.wants/omarchy-vendorfw.service' "$list" ||
  fail "lsinitcpio lists the initrd.target wants symlink for the late unit" "$(cat "$list")"
if grep -Fq 'tpmtfw-' "$list"; then
  fail "the image must not bake MTP firmware; the early helper unpacks it from the ESP"
fi
echo 'ok - lsinitcpio lists HID modules, thunderbolt, both vendorfw units and generated wants links'

extract=$tmp/initrd
mkdir -p "$extract"
(cd "$extract" && lsinitcpio -x "$img")
[[ -f $extract/usr/lib/systemd/system/omarchy-vendorfw-initrd.service ]] ||
  fail "extracted initramfs contains omarchy-vendorfw-initrd.service"
[[ -L $extract/usr/lib/systemd/system/cryptsetup-pre.target.wants/omarchy-vendorfw-initrd.service ]] ||
  fail "extracted initramfs contains cryptsetup-pre.target.wants/omarchy-vendorfw-initrd.service"
[[ -L $extract/usr/lib/systemd/system/initrd-root-device.target.wants/omarchy-vendorfw-initrd.service ]] ||
  fail "extracted initramfs contains initrd-root-device.target.wants/omarchy-vendorfw-initrd.service"
[[ -L $extract/usr/lib/systemd/system/sysinit.target.wants/omarchy-vendorfw-initrd.service ]] ||
  fail "extracted initramfs contains sysinit.target.wants/omarchy-vendorfw-initrd.service"
[[ -f "$extract/usr/lib/systemd/system/systemd-cryptsetup@.service.d/omarchy-vendorfw-initrd.conf" ]] ||
  fail "extracted initramfs contains the systemd-cryptsetup@.service drop-in"
[[ -L $extract/usr/lib/systemd/system/initrd.target.wants/omarchy-vendorfw.service ]] ||
  fail "extracted initramfs contains initrd.target.wants/omarchy-vendorfw.service"

verify_out=$tmp/verify.out
if ! systemd-analyze --root="$extract" --man=no verify \
  omarchy-vendorfw-initrd.service \
  omarchy-vendorfw.service \
  >"$verify_out" 2>&1; then
  fail "systemd-analyze verify rejected the initrd units" "$(cat "$verify_out")"
fi
echo 'ok - systemd-analyze verify accepts the early and late vendorfw units'

install -Dm644 /dev/stdin "$extract/usr/lib/systemd/system/omarchy-mac-encrypt.service" <<'UNIT'
[Unit]
Description=Stub T4a encrypt unit for vendorfw ordering
DefaultDependencies=no
Wants=omarchy-vendorfw-initrd.service
After=omarchy-vendorfw-initrd.service
Before=cryptsetup-pre.target initrd-root-device.target sysroot.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
UNIT
gen=$tmp/cryptsetup-gen
mkdir -p "$gen"
[[ -f /etc/crypttab ]] || fail "/etc/crypttab must exist so systemd-cryptsetup@root can be instantiated"
/usr/lib/systemd/system-generators/systemd-cryptsetup-generator "$gen" "$gen" "$gen"
[[ -f $gen/systemd-cryptsetup@root.service ]] ||
  fail "systemd-cryptsetup-generator did not instantiate systemd-cryptsetup@root.service" "$(ls -la "$gen")"
install -Dm644 "$gen/systemd-cryptsetup@root.service" \
  "$extract/usr/lib/systemd/system/systemd-cryptsetup@root.service"
if ! systemd-analyze --root="$extract" --man=no verify \
  systemd-cryptsetup@root.service \
  >"$verify_out" 2>&1; then
  fail "systemd-analyze verify rejected systemd-cryptsetup@root.service with the vendorfw drop-in" "$(cat "$verify_out")"
fi
grep -Fq 'Wants=omarchy-vendorfw-initrd.service' \
  "$extract/usr/lib/systemd/system/systemd-cryptsetup@.service.d/omarchy-vendorfw-initrd.conf" ||
  fail "the instantiated cryptsetup graph includes the vendorfw drop-in"
if ! systemd-analyze --root="$extract" --man=no verify \
  omarchy-mac-encrypt.service \
  omarchy-vendorfw-initrd.service \
  systemd-cryptsetup@root.service \
  >"$verify_out" 2>&1; then
  fail "systemd-analyze verify found a cycle in the encrypt/vendorfw graph" "$(cat "$verify_out")"
fi
if grep -Ei 'cyclic|cycle' "$verify_out"; then
  fail "the encrypt/vendorfw graph must not contain a cycle" "$(cat "$verify_out")"
fi
echo 'ok - systemd-analyze verify accepts systemd-cryptsetup@root.service and the stub encrypt unit without a cycle'

# Fixture ESP: fake UUID node + blkid, recorded mount/cpio, firmware at the
# kernel loader path, existing vendor file not hidden.
esp=$tmp/esp
cpiosrc=$tmp/cpio-src
calls=$tmp/helper.calls
: >"$calls"
mkdir -p "$esp/vendorfw" "$cpiosrc/vendorfw/apple" "$cpiosrc/vendorfw/brcm" "$tmp/helper-bin"
printf 'mtp-j416c\n' >"$cpiosrc/vendorfw/apple/tpmtfw-j416c.bin"
printf 'mtp-j413\n' >"$cpiosrc/vendorfw/apple/tpmtfw-j413.bin"
printf 'wifi\n' >"$cpiosrc/vendorfw/brcm/brcmfmac.bin"
printf 'manifest\n' >"$cpiosrc/vendorfw/.vendorfw.manifest"
(cd "$cpiosrc" && find . -print | cpio -o -H newc --quiet) >"$esp/vendorfw/firmware.cpio"

real_umount=$(command -v umount)
real_cpio=$(command -v cpio)
cat >"$tmp/helper-bin/mount" <<SH
#!/bin/sh
printf 'mount %s\n' "\$*" >>"$calls"
last=
for last; do :; done
mkdir -p "\$last"
case " \$* " in
  *" -t tmpfs "*|*" tmpfs "*) exit 0 ;;
esac
cp -a "$esp"/. "\$last"/
exit 0
SH
cat >"$tmp/helper-bin/umount" <<SH
#!/bin/sh
printf 'umount %s\n' "\$*" >>"$calls"
"$real_umount" "\$@" 2>/dev/null || true
exit 0
SH
cat >"$tmp/helper-bin/cpio" <<SH
#!/bin/sh
printf 'cpio %s\n' "\$*" >>"$calls"
exec "$real_cpio" "\$@"
SH
cat >"$tmp/helper-bin/blkid" <<SH
#!/bin/sh
printf 'blkid %s\n' "\$*" >>"$calls"
if [ "\$1" = -U ] && [ "\$2" = 4F4D-5801 ] && [ -e /dev/disk/by-uuid/4F4D-5801 ]; then
  printf '%s\n' /dev/disk/by-uuid/4F4D-5801
  exit 0
fi
exit 1
SH
cat >"$tmp/helper-bin/udevadm" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$tmp/helper-bin"/{mount,umount,cpio,blkid,udevadm}

mkdir -p /dev/disk/by-uuid /lib/firmware /vendorfw/keep
printf 'sentinel\n' >/vendorfw/keep/already-there.bin
ln -sfn /vendorfw /lib/firmware/vendor
touch /dev/disk/by-uuid/4F4D-5801
rm -f /run/omarchy-vendorfw-initrd.staged
rm -rf /run/omarchy-vendorfw-esp /run/omarchy-vendorfw-extract

PATH="$tmp/helper-bin:$PATH" /usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.sh ||
  fail "the early helper ran against the fixture ESP" "$(cat "$calls" 2>/dev/null || true)"

grep -q '^mount ' "$calls" || fail "the early helper mounted the ESP" "$(cat "$calls")"
grep -q '^cpio ' "$calls" || fail "the early helper extracted firmware.cpio" "$(cat "$calls")"
[[ -f /lib/firmware/vendor/apple/tpmtfw-j416c.bin ]] ||
  fail "firmware landed at /lib/firmware/vendor (kernel loader path)"
[[ $(cat /lib/firmware/vendor/apple/tpmtfw-j416c.bin) == mtp-j416c ]] ||
  fail "extracted MTP firmware contents are intact"
[[ -f /lib/firmware/vendor/apple/tpmtfw-j413.bin ]] ||
  fail "M2 Air MTP firmware was extracted"
[[ -f /lib/firmware/vendor/brcm/brcmfmac.bin ]] ||
  fail "Wi-Fi firmware from the cpio was extracted, not only trackpad blobs"
[[ $(cat /vendorfw/keep/already-there.bin) == sentinel ]] ||
  fail "existing firmware on the vendor tree must not be hidden"
[[ -f /run/omarchy-vendorfw-initrd.staged ]] ||
  fail "the early helper recorded what it staged"
grep -Fq '4F4D-5801' /run/omarchy-vendorfw-initrd.staged ||
  fail "the staging record names the ESP UUID device"
echo 'ok - early helper mounts the ESP, extracts firmware.cpio, and does not hide existing vendor files'

reset_helper() {
  : >"$calls"
  rm -f /run/omarchy-vendorfw-initrd.staged /run/omarchy-vendorfw-initrd.status
  rm -rf /run/omarchy-vendorfw-esp /run/omarchy-vendorfw-extract
}

reset_helper
rm -f /dev/disk/by-uuid/4F4D-5801
( sleep 0.3 && mkdir -p /dev/disk/by-uuid && touch /dev/disk/by-uuid/4F4D-5801 ) &
PATH="$tmp/helper-bin:$PATH" /usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.sh \
  >"$tmp/delayed.out" 2>"$tmp/delayed.err" ||
  fail "a delayed ESP must not fail the helper" "$(cat "$tmp/delayed.err")"
wait
[[ -f /run/omarchy-vendorfw-initrd.staged ]] ||
  fail "a delayed ESP still stages vendor firmware" "$(cat "$tmp/delayed.err")"
[[ ! -e /run/omarchy-vendorfw-initrd.status ]] ||
  fail "a delayed ESP that appears must not record status=missing"
echo 'ok - delayed ESP appearance still stages vendor firmware'

reset_helper
rm -f "$esp/vendorfw/firmware.cpio"
PATH="$tmp/helper-bin:$PATH" /usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.sh \
  >"$tmp/nocpio.out" 2>"$tmp/nocpio.err" ||
  fail "missing firmware.cpio must still exit 0" "$(cat "$tmp/nocpio.err")"
[[ $(cat /run/omarchy-vendorfw-initrd.status 2>/dev/null) == missing ]] ||
  fail "missing firmware.cpio records status=missing" "$(cat "$tmp/nocpio.err")"
grep -Fq 'firmware.cpio' "$tmp/nocpio.err" ||
  fail "missing firmware.cpio logs a specific error" "$(cat "$tmp/nocpio.err")"
echo 'ok - missing firmware.cpio records status=missing and exits 0'

reset_helper
rm -f /dev/disk/by-uuid/4F4D-5801
cat >"$tmp/helper-bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$tmp/helper-bin/sleep"
PATH="$tmp/helper-bin:$PATH" /usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.sh \
  >"$tmp/noesp.out" 2>"$tmp/noesp.err" ||
  fail "a missing ESP must still exit 0" "$(cat "$tmp/noesp.err")"
[[ $(cat /run/omarchy-vendorfw-initrd.status 2>/dev/null) == missing ]] ||
  fail "a missing ESP records status=missing" "$(cat "$tmp/noesp.err")"
grep -Fq '4F4D-5801' "$tmp/noesp.err" ||
  fail "a missing ESP logs a specific error" "$(cat "$tmp/noesp.err")"
echo 'ok - missing ESP records status=missing and exits 0'
echo 'ok - omarchy-mac-hid-initramfs'
