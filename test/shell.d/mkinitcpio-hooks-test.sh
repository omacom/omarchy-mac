#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

etc="$test_tmp/etc"
devices="$test_tmp/devices"

omarchy_hooks="base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs"
omarchy_hooks_without_kms=${omarchy_hooks/ kms / }
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
# sources the result once. Do the same and print what the image is built from.
# The vconsole.conf entry comes from the host's own file, so it is left out of
# FILES.
compose() {
  local config="$test_tmp/buildconfig" conf
  local -a conf_files=()
  mapfile -d '' conf_files < <(LC_ALL=C.UTF-8 find "$etc/mkinitcpio.conf.d" -maxdepth 1 -xtype f -name '*.conf' -print0 |
    sed -z 's/.*\///' | LC_ALL=C.UTF-8 sort -zVu)
  cat -- "$etc/mkinitcpio.conf" >"$config"
  for conf in "${conf_files[@]}"; do
    cat -- "$etc/mkinitcpio.conf.d/$conf" >>"$config"
  done

  OMARCHY_PCI_DEVICES_PATH="$devices" "$BASH" -c '
    . "$1" || exit 1
    files=()
    for file in "${FILES[@]}"; do
      [[ $file == /etc/vconsole.conf ]] || files+=("$file")
    done
    printf "HOOKS=%s\nMODULES=%s\nFILES=%s\n" "${HOOKS[*]}" "${MODULES[*]}" "${files[*]}"
  ' -- "$config"
}

assert_composed() {
  local description="$1" hooks="$2" modules="$3" files="$4"
  local expected actual
  expected=$(printf 'HOOKS=%s\nMODULES=%s\nFILES=%s\n' "$hooks" "$modules" "$files")
  actual=$(compose) || fail "$description" "the drop-ins do not source cleanly"
  [[ $actual == "$expected" ]] ||
    fail "$description" "expected:"$'\n'"$expected"$'\n'"actual:"$'\n'"$actual"
  pass "$description"
}

assert_hooks() {
  local description="$1" expected="$2" actual
  actual=$(compose) || fail "$description" "the drop-ins do not source cleanly"
  actual=$(sed -n 's/^HOOKS=//p' <<<"$actual")
  [[ $actual == "$expected" ]] ||
    fail "$description" "expected: $expected"$'\n'"actual:   $actual"
  pass "$description"
}

# The baseline replaces whatever mkinitcpio.conf says.
new_etc
assert_hooks "the Omarchy baseline replaces mkinitcpio.conf's HOOKS" "$omarchy_hooks"

# A fragment that sorts after the baseline and before omarchy_hooks.conf, as a
# platform's numbered drop-ins do. Its hooks must reach the image.
drop_in 90-platform-fragment.conf <<'CONF'
_fragment_hooks=()
for _fragment_hook in "${HOOKS[@]}"; do
  [[ $_fragment_hook == "filesystems" ]] && _fragment_hooks+=(platform-firmware)
  _fragment_hooks+=("$_fragment_hook")
done
HOOKS=("${_fragment_hooks[@]}" platform-late)
unset _fragment_hooks _fragment_hook
CONF
assert_hooks "a numbered fragment's hooks survive omarchy_hooks.conf" \
  "base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt platform-firmware filesystems fsck btrfs-overlayfs platform-late"

# The NVIDIA filter still runs after the fragment and removes only kms.
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
pci_devices 0x10de:0x030000
assert_hooks "the NVIDIA filter keeps a numbered fragment's hooks" \
  "base udev plymouth keyboard autodetect microcode modconf keymap consolefont block encrypt platform-firmware filesystems fsck btrfs-overlayfs platform-late"

# Existing configurations build the image they built before the baseline
# moved: the same HOOKS, MODULES and FILES.
new_etc
assert_composed "a machine without hardware drop-ins is unchanged" \
  "$omarchy_hooks" "thunderbolt?" ""

new_etc
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
pci_devices 0x10de:0x030000
assert_composed "NVIDIA-only drops only kms" \
  "$omarchy_hooks_without_kms" "$nvidia_modules thunderbolt?" ""

new_etc
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
pci_devices 0x8086:0x030000 0x10de:0x030200
assert_composed "hybrid graphics keeps kms for the iGPU" \
  "$omarchy_hooks" "$nvidia_modules thunderbolt?" ""

new_etc
pci_devices 0x10de:0x030000
assert_composed "NVIDIA-only without early nvidia_drm keeps kms" \
  "$omarchy_hooks" "thunderbolt?" ""

new_etc
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
drop_in omarchy_resume.conf <<<"HOOKS+=(resume)"
drop_in 99-omarchy-provisioning-key.conf <<<"FILES+=(/etc/omarchy/provisioning.key)"
pci_devices 0x10de:0x030000
assert_composed "NVIDIA-only with hibernation and a provisioning key is unchanged" \
  "$omarchy_hooks_without_kms resume" "$nvidia_modules thunderbolt?" "/etc/omarchy/provisioning.key"

new_etc
drop_in apple-t2.conf <<<"MODULES+=(t2bce_vhci usbhid hid_apple hid_generic xhci_pci xhci_hcd)"
assert_composed "a T2 Mac is unchanged" \
  "$omarchy_hooks" "t2bce_vhci usbhid hid_apple hid_generic xhci_pci xhci_hcd thunderbolt?" ""

new_etc
drop_in macbook_spi_modules.conf <<<"MODULES=(applespi intel_lpss_pci spi_pxa2xx_platform)"
assert_composed "an SPI keyboard MacBook is unchanged" \
  "$omarchy_hooks" "applespi intel_lpss_pci spi_pxa2xx_platform thunderbolt?" ""

new_etc
drop_in nvidia.conf <<<"MODULES+=($nvidia_modules)"
drop_in surface_device_modules.conf <<<"MODULES=(pinctrl_tigerlake surface_aggregator surface_aggregator_registry surface_aggregator_hub surface_hid_core surface_hid surface_kbd intel_lpss_pci 8250_dw)"
pci_devices 0x8086:0x030000
assert_composed "a Surface is unchanged" \
  "$omarchy_hooks" "pinctrl_tigerlake surface_aggregator surface_aggregator_registry surface_aggregator_hub surface_hid_core surface_hid surface_kbd intel_lpss_pci 8250_dw thunderbolt?" ""
