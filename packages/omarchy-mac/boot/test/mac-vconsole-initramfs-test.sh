#!/bin/bash

# 94-omarchy-mac-vconsole.conf: the Mac initramfs carries the owner's keyboard
# layout to the disk passphrase prompt (sd-vconsole + /etc/vconsole.conf), and
# keeps a layout that cannot type Latin letters out (upstream #6229). The HOOKS
# cases source a copy that reads a scratch vconsole.conf; building a real image
# runs in an Arch ARM container (OMARCHY_DISPOSABLE_BOOT_TESTS=1 opts in).

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
confd=$ROOT/files/etc/mkinitcpio.conf.d
dropin=$confd/94-omarchy-mac-vconsole.conf

fail() {
  echo "not ok - $1" >&2
  [[ $# -lt 2 ]] || printf '%s\n' "$2" >&2
  exit 1
}

[[ -f $dropin ]] || fail "94-omarchy-mac-vconsole.conf is in the package files tree"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Inside the container the drop-in reads the real /etc/vconsole.conf.
vconsole_conf=/etc/vconsole.conf
if [[ ${IN_OMARCHY_MAC_VCONSOLE_TEST:-} != 1 ]]; then
  vconsole_conf=$tmp/vconsole.conf
  mkdir -p "$tmp/confd"
  for file in "$confd"/*.conf; do
    sed "s|/etc/vconsole.conf|$vconsole_conf|g" "$file" >"$tmp/confd/${file##*/}"
  done
  confd=$tmp/confd
  dropin=$confd/94-omarchy-mac-vconsole.conf
fi

vconsole() {
  if [[ $# -eq 0 ]]; then
    rm -f "$vconsole_conf"
  else
    printf '%s\n' "$@" >"$vconsole_conf"
  fi
}

# Sources the given drop-ins over a HOOKS line; prints status, HOOKS, FILES and
# any variable the drop-ins left behind.
after() {
  local files=$1
  shift
  XKBLAYOUT=ru bash -c '
    HOOKS=("${@:2}")
    FILES=()
    for f in $1; do source "$f" || exit 1; done
    printf "%s\n" "$?" "${HOOKS[*]}" "${FILES[*]}" "$(compgen -v | grep _omarchy_mac_vconsole || true)"
  ' bash "$files" "$@"
}

stock=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)

vconsole KEYMAP=dk-latin1 XKBLAYOUT=dk XKBMODEL=pc105
mapfile -t out < <(after "$dropin" "${stock[@]}")
[[ ${out[0]} == 0 ]] || fail "the drop-in sources cleanly" "status ${out[0]}"
[[ ${out[1]} == "${stock[*]}" ]] || fail "a stock line keeps sd-vconsole right after keyboard" "HOOKS=(${out[1]})"
[[ ${out[2]} == "$vconsole_conf" ]] || fail "a Latin layout bundles /etc/vconsole.conf" "FILES=(${out[2]})"
[[ -z ${out[3]} ]] || fail "the drop-in leaves no variable behind" "${out[3]}"
echo 'ok - Danish: sd-vconsole stays after keyboard and vconsole.conf is bundled (an exported XKBLAYOUT does not leak in)'

mapfile -t out < <(after "$dropin" base systemd autodetect keyboard block filesystems)
[[ ${out[1]} == "base systemd autodetect keyboard sd-vconsole block filesystems" ]] ||
  fail "a systemd line without sd-vconsole gets it after keyboard" "HOOKS=(${out[1]})"
mapfile -t out < <(after "$dropin" base systemd sd-vconsole block keymap consolefont sd-vconsole filesystems)
[[ ${out[1]} == "base systemd sd-vconsole block filesystems" ]] ||
  fail "without keyboard, sd-vconsole lands once after systemd; busybox keymap/consolefont go" "HOOKS=(${out[1]})"
mapfile -t out < <(after "$dropin $dropin" "${stock[@]}")
[[ ${out[1]} == "${stock[*]}" && ${out[2]} == "$vconsole_conf $vconsole_conf" ]] ||
  fail "sourcing twice never duplicates the hook" "HOOKS=(${out[1]}) FILES=(${out[2]})"
echo 'ok - a systemd line gets sd-vconsole exactly once, after keyboard or systemd'

busybox=(base udev autodetect keyboard keymap block encrypt filesystems fsck)
mapfile -t out < <(after "$dropin" "${busybox[@]}")
[[ ${out[1]} == "${busybox[*]}" && ${out[2]} == "$vconsole_conf" ]] ||
  fail "a busybox cryptdevice= line keeps its hooks and gets the file for Plymouth" "HOOKS=(${out[1]}) FILES=(${out[2]})"
echo 'ok - a busybox (cryptdevice=) line is left alone apart from the file'

vconsole KEYMAP=ru XKBLAYOUT=ru,us
mapfile -t out < <(after "$dropin" "${stock[@]}")
[[ ${out[1]} == "base systemd autodetect microcode modconf kms keyboard block filesystems fsck" && -z ${out[2]} ]] ||
  fail "a non-Latin layout stays out of the initramfs" "HOOKS=(${out[1]}) FILES=(${out[2]})"
vconsole KEYMAP=gr XKBLAYOUT=gr
mapfile -t out < <(after "$dropin" "${stock[@]}")
[[ ${out[1]} != *sd-vconsole* && -z ${out[2]} ]] || fail "Greek stays out too" "HOOKS=(${out[1]}) FILES=(${out[2]})"
echo 'ok - a non-Latin layout keeps the passphrase prompt on the US map (upstream #6229 guard)'

vconsole
mapfile -t out < <(after "$dropin" "${stock[@]}")
[[ ${out[0]} == 0 && ${out[1]} == "${stock[*]}" && -z ${out[2]} ]] ||
  fail "no vconsole.conf keeps sd-vconsole and bundles nothing" "status ${out[0]} HOOKS=(${out[1]}) FILES=(${out[2]})"
echo 'ok - without vconsole.conf the line is unchanged and nothing is bundled'

# The whole Mac chain over the stock line: 90 → 94, as mkinitcpio sources them.
vconsole KEYMAP=dk-latin1 XKBLAYOUT=dk
chain="$confd/90-omarchy-mac.conf $confd/91-omarchy-mac-encrypt.conf $confd/93-omarchy-mac-plymouth.conf $dropin"
mapfile -t out < <(after "$chain" base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)
[[ ${out[1]} == *"keyboard sd-vconsole block"* && ${out[1]} == *"sd-encrypt filesystems"* ]] ||
  fail "the full Mac chain ends with sd-vconsole after keyboard and sd-encrypt before filesystems" "HOOKS=(${out[1]})"
(( $(grep -o sd-vconsole <<<"${out[1]}" | wc -l) == 1 )) || fail "the chain has one sd-vconsole" "HOOKS=(${out[1]})"
echo 'ok - 90..94 over the stock busybox line: one sd-vconsole, after keyboard'

if [[ ${OMARCHY_DISPOSABLE_BOOT_TESTS:-0} != "1" && ${IN_OMARCHY_MAC_VCONSOLE_TEST:-0} != "1" ]]; then
  echo 'ok - source checks passed; disposable initramfs tests not run (OMARCHY_DISPOSABLE_BOOT_TESTS=1 opts in)'
  exit 0
fi

if [[ ${IN_OMARCHY_MAC_VCONSOLE_TEST:-} != 1 ]]; then
  command -v docker >/dev/null 2>&1 ||
    fail "docker is required to build the initramfs in an Arch container"
  exec docker run --rm --privileged --platform linux/arm64 \
    -e IN_OMARCHY_MAC_VCONSOLE_TEST=1 \
    -v "$ROOT:/repo:ro" \
    -w /repo \
    menci/archlinuxarm:latest \
    bash /repo/test/mac-vconsole-initramfs-test.sh
fi

[[ $(uname -m) == aarch64 ]] || fail "the container architecture must be aarch64 (got $(uname -m))"

# A real image: the keymap and vconsole.conf reach it, and a non-Latin layout does not.
pacman --disable-sandbox -Sy --noconfirm --needed mkinitcpio kbd systemd binutils kmod >/dev/null 2>&1
kver=$(uname -r)
mkdir -p "/lib/modules/$kver/kernel/extra"
touch "/lib/modules/$kver/modules.order" "/lib/modules/$kver/modules.builtin" "/lib/modules/$kver/modules.builtin.modinfo"
# The systemd hook insists on these two; mint them the way the HID test does.
elf=$(find /usr/lib -type f -name 'libc.so*' 2>/dev/null | head -1)
[[ -n $elf ]] || fail "the container has an ELF to mint fake .ko files from"
for module in crypto_lzo crypto_lz4; do
  printf 'name=%s\0vermagic=%s SMP preempt mod_unload\0' "$module" "$kver" >"$tmp/modinfo.$module"
  objcopy --add-section ".modinfo=$tmp/modinfo.$module" \
    --set-section-flags .modinfo=contents,alloc,readonly,data \
    "$elf" "/lib/modules/$kver/kernel/extra/${module//_/-}.ko" 2>/dev/null ||
    cp "$elf" "/lib/modules/$kver/kernel/extra/${module//_/-}.ko"
done
depmod "$kver" >/dev/null 2>&1 || true
install -Dm644 "$dropin" /etc/mkinitcpio.conf.d/94-omarchy-mac-vconsole.conf
cat >/etc/mkinitcpio.conf <<'CONF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd)
COMPRESSION=gzip
CONF

build() {
  local img=$tmp/$1.img log=$tmp/$1.log
  mkinitcpio -k "$kver" -g "$img" >"$log" 2>&1 || fail "mkinitcpio built the $1 image" "$(cat "$log")"
  rm -rf "${tmp:?}/${1:?}"
  mkdir -p "$tmp/$1"
  (cd "$tmp/$1" && lsinitcpio -x "$img")
}

vconsole '# localectl' KEYMAP=dk-latin1 XKBLAYOUT=dk XKBMODEL=pc105 'XKBOPTIONS=terminate:ctrl_alt_bksp'
build danish
cmp -s "$tmp/danish/etc/vconsole.conf" /etc/vconsole.conf ||
  fail "the image carries /etc/vconsole.conf byte for byte" "$(cat "$tmp/danish/etc/vconsole.conf" 2>&1)"
find "$tmp/danish/usr/share/kbd/keymaps" -name 'dk-latin1.map*' | grep -q . ||
  fail "the image carries the dk-latin1 console keymap"
[[ -x $tmp/danish/usr/bin/loadkeys && -f $tmp/danish/usr/lib/systemd/system/systemd-vconsole-setup.service ]] ||
  fail "the image carries loadkeys and systemd-vconsole-setup"
chroot "$tmp/danish" /usr/bin/loadkeys -b dk-latin1 >/dev/null 2>&1 ||
  fail "loadkeys resolves dk-latin1 and its includes inside the image"
echo 'ok - a Danish image carries vconsole.conf, the dk-latin1 keymap and loadkeys, and the keymap resolves'

vconsole KEYMAP=ru XKBLAYOUT=ru
build russian
[[ ! -e $tmp/russian/etc/vconsole.conf ]] || fail "a Russian image carries no vconsole.conf"
! find "$tmp/russian/usr/share/kbd" -name 'ru.map*' 2>/dev/null | grep -q . || fail "a Russian image carries no ru keymap"
echo 'ok - a Russian image carries neither vconsole.conf nor the ru keymap'
