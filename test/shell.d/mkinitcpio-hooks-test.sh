#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_platform_fixtures "the composed mkinitcpio HOOKS"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$test_tmp/platforms/$platform" "$platform"
done
# omarchy-settings without the runtime package: no detector on PATH.
mkdir -p "$test_tmp/platforms/no-detector/bin"
# A device tree naming both Apple and Qualcomm, which the detector refuses.
fake_platform "$test_tmp/platforms/contradiction" apple-silicon
printf '%s\0' apple,j416c qcom,x1e80100 >"$test_tmp/platforms/contradiction/proc/device-tree/compatible"

etc="$test_tmp/etc"
devices="$test_tmp/devices"

x86_hooks="base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs"
x86_hooks_without_kms=${x86_hooks/ kms / }
apple_hooks="base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck"
nvidia_modules="nvidia nvidia_modeset nvidia_uvm nvidia_drm"

# mkinitcpio's stock mkinitcpio.conf, which the baseline replaces, plus every
# drop-in Omarchy ships, on a machine with no PCI devices.
new_etc() {
  rm -rf "$etc" "$devices"
  mkdir -p "$etc/mkinitcpio.conf.d" "$devices"
  cat >"$etc/mkinitcpio.conf" <<'CONF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
CONF
  cp "$ROOT"/etc/mkinitcpio.conf.d/*.conf "$etc/mkinitcpio.conf.d/"
}

# $1 names the drop-in; stdin is its content.
drop_in() {
  cat >"$etc/mkinitcpio.conf.d/$1"
}

# Each argument is a PCI device as "vendor:class", in sysfs's own format.
pci_devices() {
  local index=0 spec slot
  for spec in "$@"; do
    slot=$(printf '0000:%02x:00.0' "$index")
    mkdir -p "$devices/$slot"
    printf '%s\n' "${spec%%:*}" >"$devices/$slot/vendor"
    printf '%s\n' "${spec##*:}" >"$devices/$slot/class"
    index=$((index + 1))
  done
}

# mkinitcpio appends the drop-ins to mkinitcpio.conf in its own order and
# sources the result once. Do the same on a platform fixture and print what the
# image is built from. The vconsole.conf entry comes from the host's own file,
# so it is left out of FILES.
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
  [[ $1 != "no-detector" ]] || path="$fixture/bin"
  OMARCHY_PROC_ROOT="$fixture/proc" OMARCHY_PCI_DEVICES_PATH="$devices" PATH="$path" "$BASH" -c '
    . "$1" || exit 1
    files=()
    for file in "${FILES[@]}"; do
      [[ $file == /etc/vconsole.conf ]] || files+=("$file")
    done
    printf "HOOKS=%s\nMODULES=%s\nFILES=%s\n" "${HOOKS[*]}" "${MODULES[*]}" "${files[*]}"
  ' -- "$config"
}

assert_composed() {
  local description="$1" platform="$2" hooks="$3" modules="$4" files="$5"
  local expected actual
  expected=$(printf 'HOOKS=%s\nMODULES=%s\nFILES=%s\n' "$hooks" "$modules" "$files")
  actual=$(compose "$platform") || fail "$description" "the drop-ins do not source cleanly"
  [[ $actual == "$expected" ]] ||
    fail "$description" "expected:"$'\n'"$expected"$'\n'"actual:"$'\n'"$actual"
  pass "$description"
}

assert_hooks() {
  local description="$1" platform="$2" expected="$3" actual
  actual=$(compose "$platform") || fail "$description" "the drop-ins do not source cleanly"
  actual=$(sed -n 's/^HOOKS=//p' <<<"$actual")
  [[ $actual == "$expected" ]] ||
    fail "$description" "expected: $expected"$'\n'"actual:   $actual"
  pass "$description"
}

# Each platform starts from its own baseline, whatever mkinitcpio.conf says.
new_etc
assert_hooks "Apple Silicon starts from the systemd baseline" apple-silicon "$apple_hooks"
assert_hooks "Qualcomm starts from the Omarchy baseline" qualcomm "$x86_hooks"
assert_hooks "generic aarch64 starts from the Omarchy baseline" generic-aarch64 "$x86_hooks"
assert_hooks "x86 starts from the Omarchy baseline" generic "$x86_hooks"
assert_hooks "without the detector the Omarchy baseline stays" no-detector "$x86_hooks"

if composed=$(compose contradiction 2>"$test_tmp/contradiction.err"); then
  fail "a platform the detector cannot place stops the build" "composed: $composed"
fi
grep -q "contradictory platform identity" "$test_tmp/contradiction.err" ||
  fail "a platform the detector cannot place stops the build" "stderr: $(<"$test_tmp/contradiction.err")"
pass "a platform the detector cannot place stops the build"

# A platform fragment sorts after the baseline and before omarchy_hooks.conf,
# as omarchy-mac-boot's 90- drop-ins do. Its hooks must reach the image.
new_etc
drop_in 90-platform-fragment.conf <<'CONF'
_fragment_hooks=()
for _fragment_hook in "${HOOKS[@]}"; do
  [[ $_fragment_hook == "filesystems" ]] && _fragment_hooks+=(platform-firmware)
  _fragment_hooks+=("$_fragment_hook")
done
HOOKS=("${_fragment_hooks[@]}" platform-late)
unset _fragment_hooks _fragment_hook
CONF
assert_hooks "a platform fragment's hooks survive on Apple Silicon" apple-silicon \
  "base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block platform-firmware filesystems fsck platform-late"
assert_hooks "a platform fragment's hooks survive on Qualcomm" qualcomm \
  "base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt platform-firmware filesystems fsck btrfs-overlayfs platform-late"
assert_hooks "a platform fragment's hooks survive on generic aarch64" generic-aarch64 \
  "base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt platform-firmware filesystems fsck btrfs-overlayfs platform-late"
assert_hooks "a platform fragment's hooks survive on x86" generic \
  "base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt platform-firmware filesystems fsck btrfs-overlayfs platform-late"

# The NVIDIA filter still runs after the fragment and removes only kms.
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
pci_devices 0x10de:0x030000
assert_hooks "the NVIDIA filter keeps a platform fragment's hooks" generic \
  "base udev plymouth keyboard autodetect microcode modconf keymap consolefont block encrypt platform-firmware filesystems fsck btrfs-overlayfs platform-late"

# Existing x86 configurations build the image they built before the baseline
# moved: the same HOOKS, MODULES and FILES.
new_etc
assert_composed "x86 without hardware drop-ins is unchanged" generic \
  "$x86_hooks" "thunderbolt" ""

new_etc
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
pci_devices 0x10de:0x030000
assert_composed "NVIDIA-only x86 drops only kms" generic \
  "$x86_hooks_without_kms" "$nvidia_modules thunderbolt" ""

new_etc
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
pci_devices 0x8086:0x030000 0x10de:0x030200
assert_composed "hybrid x86 keeps kms for the iGPU" generic \
  "$x86_hooks" "$nvidia_modules thunderbolt" ""

new_etc
pci_devices 0x10de:0x030000
assert_composed "NVIDIA-only x86 without early nvidia_drm keeps kms" generic \
  "$x86_hooks" "thunderbolt" ""

new_etc
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
drop_in omarchy_resume.conf <<<"HOOKS+=(resume)"
drop_in 99-omarchy-provisioning-key.conf <<<"FILES+=(/etc/omarchy/provisioning.key)"
pci_devices 0x10de:0x030000
assert_composed "NVIDIA-only x86 with hibernation and a provisioning key is unchanged" generic \
  "$x86_hooks_without_kms resume" "$nvidia_modules thunderbolt" "/etc/omarchy/provisioning.key"

new_etc
drop_in apple-t2.conf <<<"MODULES+=(t2bce_vhci usbhid hid_apple hid_generic xhci_pci xhci_hcd)"
assert_composed "T2 Mac x86 is unchanged" generic \
  "$x86_hooks" "t2bce_vhci usbhid hid_apple hid_generic xhci_pci xhci_hcd thunderbolt" ""

new_etc
drop_in macbook_spi_modules.conf <<<"MODULES=(applespi intel_lpss_pci spi_pxa2xx_platform)"
assert_composed "SPI keyboard MacBook x86 is unchanged" generic \
  "$x86_hooks" "applespi intel_lpss_pci spi_pxa2xx_platform thunderbolt" ""

new_etc
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
drop_in surface_device_modules.conf <<<"MODULES=(pinctrl_tigerlake surface_aggregator surface_aggregator_registry surface_aggregator_hub surface_hid_core surface_hid surface_kbd intel_lpss_pci 8250_dw)"
pci_devices 0x8086:0x030000
assert_composed "Surface x86 is unchanged" generic \
  "$x86_hooks" "pinctrl_tigerlake surface_aggregator surface_aggregator_registry surface_aggregator_hub surface_hid_core surface_hid surface_kbd intel_lpss_pci 8250_dw thunderbolt" ""
