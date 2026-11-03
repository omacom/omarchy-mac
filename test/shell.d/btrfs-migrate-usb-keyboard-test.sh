#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The encryption passphrase prompt runs in the initramfs, so a USB keyboard
# only works there if the USB-C controller and HID modules are in the image
# (issue #743: a Mac Studio's keyboard was dead because dwc3_apple and
# apple_tunable were missing). The staging writes a drop-in that adds the ones
# a kernel has, checked when each image is built for the kernel being built,
# not the running one (a kernel update without a reboot builds for another).

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Only the kernel being built (9.9.9) has modules, and not tps6598x. The
# running kernel (uname) has none, as after an update that removed its modules.
modinfo() {
  [[ $1 == -k && $2 == 9.9.9 && $3 != tps6598x ]]
}
uname() { echo 7.1.13-running; }

(
  source "$ROOT/bin/omarchy-system-btrfs-migrate"
  dropin=$work/conf.d/20-omarchy-usb-keyboard.conf

  write_usb_keyboard_dropin "$work/plain.d" 0
  [[ ! -e $work/plain.d ]] || fail 'no encryption, no drop-in'
  pass 'no drop-in without encryption'

  write_usb_keyboard_dropin "$work/conf.d" 1
  [[ -f $dropin ]] || fail 'encryption writes the mkinitcpio drop-in'
  pass 'encryption writes a drop-in'

  # mkinitcpio sources the drop-in with KERNELVERSION set for the image.
  MODULES=(btrfs)
  KERNELVERSION=9.9.9
  source "$dropin"
  modules=" ${MODULES[*]} "
  [[ $modules == *' btrfs '* ]] || fail 'the drop-in keeps the modules already listed' "$modules"
  [[ $modules == *' dwc3_apple '* && $modules == *' apple_tunable '* ]] ||
    fail 'the Apple USB-C controller modules are added for the kernel being built' "$modules"
  [[ $modules != *tps6598x* ]] || fail 'a module that kernel lacks is left out' "$modules"
  [[ -z ${_omarchy_usb_keyboard_module:-} ]] || fail 'the drop-in leaves no variable behind'
  pass 'the drop-in adds the modules the kernel being built has'

  MODULES=()
  KERNELVERSION=1.2.3
  source "$dropin"
  (( ${#MODULES[@]} == 0 )) || fail 'a kernel with none of them gets none' "${MODULES[*]}"
  pass 'a kernel without the modules gets none'
)
