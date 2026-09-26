#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_platform_fixtures "the composed Apple initramfs"

# omarchy-mac-boot's drop-ins on top of omarchy-settings' HOOKS baseline, as
# mkinitcpio composes them: on Apple Silicon they give the initramfs mx-mac
# builds today, and on every other platform they change nothing.
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

boot_confd="$ROOT/packages/omarchy-mac/boot/files/etc/mkinitcpio.conf.d"
etc="$test_tmp/etc"
vconsole_conf="$test_tmp/vconsole.conf"

# The Aurora kernel on an M2 Max: these HID and Thunderbolt drivers are modules,
# the SPI HID driver is built in, and the rest do not exist.
fake_modinfo() {
  cat >"$1/modinfo" <<'SH'
#!/bin/bash
module=${*: -1}
case $module in
  hid_apple | hid_magicmouse | dockchannel-hid | usbhid | thunderbolt | thunderbolt_apple)
    printf '/usr/lib/modules/test/kernel/%s.ko.zst\n' "$module" ;;
  spi-hid-apple-of) printf '(builtin)\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/modinfo"
}

# omarchy-mac-boot depends on the runtime, so every fixture has the detector;
# the package's own tests cover a runtime too old to ship it.
for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$test_tmp/platforms/$platform" "$platform"
  fake_modinfo "$test_tmp/platforms/$platform/bin"
done

# mkinitcpio's stock mkinitcpio.conf and Omarchy's drop-ins, reading a scratch
# vconsole.conf. $1 is 1 to install omarchy-mac-boot's drop-ins too.
new_etc() {
  local with_boot=$1 conf
  rm -rf "$etc"
  mkdir -p "$etc/mkinitcpio.conf.d"
  cat >"$etc/mkinitcpio.conf" <<'CONF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
CONF
  for conf in "$ROOT"/etc/mkinitcpio.conf.d/*.conf; do
    sed "s|/etc/vconsole.conf|$vconsole_conf|g" "$conf" >"$etc/mkinitcpio.conf.d/${conf##*/}"
  done
  if (( with_boot )); then
    for conf in "$boot_confd"/*.conf; do
      sed "s|/etc/vconsole.conf|$vconsole_conf|g" "$conf" >"$etc/mkinitcpio.conf.d/${conf##*/}"
    done
  fi
}

# mkinitcpio appends the drop-ins to mkinitcpio.conf in its own order and
# sources the result once. Print what the image is built from, and any helper
# variable a drop-in left behind.
compose() {
  local fixture="$test_tmp/platforms/$1" config="$test_tmp/buildconfig" conf
  local -a conf_files=()
  mapfile -d '' conf_files < <(LC_ALL=C.UTF-8 find "$etc/mkinitcpio.conf.d" -maxdepth 1 -xtype f -name '*.conf' -print0 |
    sed -z 's/.*\///' | LC_ALL=C.UTF-8 sort -zVu)
  cat -- "$etc/mkinitcpio.conf" >"$config"
  for conf in "${conf_files[@]}"; do
    cat -- "$etc/mkinitcpio.conf.d/$conf" >>"$config"
  done

  local path="$fixture/bin:$ROOT/bin:$PATH"
  KERNELVERSION=7.1.12-test OMARCHY_PROC_ROOT="$fixture/proc" OMARCHY_PCI_DEVICES_PATH="$test_tmp/no-pci" PATH="$path" \
    "$BASH" -c '
      . "$1" || exit 1
      left=()
      for variable in $(compgen -v); do
        [[ $variable != _omarchy* ]] || left+=("$variable")
      done
      printf "HOOKS=%s\nMODULES=%s\nFILES=%s\nLEFT=%s\n" "${HOOKS[*]}" "${MODULES[*]}" "${FILES[*]}" "${left[*]}"
    ' -- "$config"
}

field() {
  sed -n "s/^$1=//p" <<<"$2"
}

# mkinitcpio loads a module once however often MODULES names it, and a
# trailing ? only makes it optional, so compare the set of modules.
module_set() {
  tr ' ' '\n' <<<"$1" | sed 's/?$//' | sed '/^$/d' | LC_ALL=C sort -u | tr '\n' ' '
}

# Captured on the M2 Max (mx-mac, omarchy-mac-boot 20260921-10, mkinitcpio 42,
# linux-aurora 7.1.12, a US layout): stock mkinitcpio.conf plus 90- to 94- and
# the runtime's apple_hid_modules.conf.
mx_hooks="base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block asahi omarchy-vendorfw omarchy-mac-encrypt sd-encrypt filesystems fsck"
mx_modules="hid_apple hid_magicmouse dockchannel-hid usbhid thunderbolt thunderbolt_apple hid_apple hid_magicmouse"

printf 'KEYMAP=us\nXKBLAYOUT=us\n' >"$vconsole_conf"
new_etc 1
composed=$(compose apple-silicon) || fail "the Apple drop-ins source cleanly on the baseline"
[[ $(field HOOKS "$composed") == "$mx_hooks" ]] ||
  fail "Apple Silicon gets mx-mac's HOOKS: asahi, vendor firmware, conversion and sd-encrypt" \
    "expected: $mx_hooks"$'\n'"actual:   $(field HOOKS "$composed")"
[[ $(module_set "$(field MODULES "$composed")") == "$(module_set "$mx_modules")" ]] ||
  fail "Apple Silicon early-loads mx-mac's modules" \
    "expected: $(module_set "$mx_modules")"$'\n'"actual:   $(module_set "$(field MODULES "$composed")")"
[[ $(field FILES "$composed") == "$vconsole_conf" ]] ||
  fail "Apple Silicon bundles vconsole.conf once, as mx-mac does" "FILES=($(field FILES "$composed"))"
[[ -z $(field LEFT "$composed") ]] || fail "the drop-ins leave no variable behind" "$(field LEFT "$composed")"
pass "Apple Silicon composes the initramfs mx-mac builds today"

printf 'KEYMAP=ru\nXKBLAYOUT=ru,us\n' >"$vconsole_conf"
composed=$(compose apple-silicon) || fail "the Apple drop-ins source cleanly with a non-Latin layout"
[[ $(field HOOKS "$composed") == "${mx_hooks/ sd-vconsole / }" && -z $(field FILES "$composed") ]] ||
  fail "a non-Latin layout keeps sd-vconsole and vconsole.conf out of the Apple initramfs" \
    "HOOKS=($(field HOOKS "$composed")) FILES=($(field FILES "$composed"))"
pass "a non-Latin layout keeps sd-vconsole and vconsole.conf out of the Apple initramfs"

# A legacy Mac unlocked through cryptdevice= keeps its busybox line, and the
# asahi hook marks an Apple root off a Mac too, as in a VM: the Apple drop-ins
# follow the baseline there.
printf 'KEYMAP=us\nXKBLAYOUT=us\n' >"$vconsole_conf"
legacy="base asahi udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck"
new_etc 1
sed -i "s/^HOOKS=.*/HOOKS=($legacy)/" "$etc/mkinitcpio.conf"
composed=$(compose apple-silicon) || fail "the Apple drop-ins source cleanly over a legacy busybox line"
[[ $(field HOOKS "$composed") == "$legacy" ]] ||
  fail "a legacy cryptdevice= Mac keeps its busybox line" "HOOKS=($(field HOOKS "$composed"))"
pass "a legacy cryptdevice= Mac keeps its busybox line"

new_etc 1
sed -i "s/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block asahi omarchy-vendorfw filesystems fsck)/" "$etc/mkinitcpio.conf"
composed=$(compose generic-aarch64) || fail "the Apple drop-ins source cleanly on an asahi root off a Mac"
[[ $(field HOOKS "$composed") == "base systemd autodetect microcode modconf kms keyboard sd-vconsole block asahi omarchy-vendorfw omarchy-mac-encrypt sd-encrypt filesystems fsck" &&
  $(module_set "$(field MODULES "$composed")") == "$(module_set "$mx_modules")" ]] ||
  fail "an asahi root off a Mac keeps the Apple unlock and modules" "$composed"
pass "an asahi root off a Mac keeps the Apple unlock and modules"

# Elsewhere, installing omarchy-mac-boot changes nothing: not HOOKS, MODULES or
# FILES, whichever layout the machine has.
for layout in us ru; do
  printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$layout" "$layout" >"$vconsole_conf"
  for platform in qualcomm generic-aarch64 generic; do
    new_etc 0
    without=$(compose "$platform") || fail "the baseline sources cleanly on $platform"
    new_etc 1
    with=$(compose "$platform") || fail "the Apple drop-ins source cleanly on $platform"
    [[ $with == "$without" ]] ||
      fail "omarchy-mac-boot's drop-ins contribute nothing on $platform ($layout layout)" \
        "without:"$'\n'"$without"$'\n'"with:"$'\n'"$with"
    [[ $(field HOOKS "$with") != *asahi* && -z $(field LEFT "$with") ]] ||
      fail "omarchy-mac-boot's drop-ins contribute nothing on $platform ($layout layout)" "$with"
  done
done
pass "omarchy-mac-boot's drop-ins contribute nothing on Qualcomm, generic aarch64 or x86"
