#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The encryption passphrase prompt runs in the initramfs, so a USB keyboard
# only works there if the USB-C controller and HID modules are in the image
# (issue #743: a Mac Studio's keyboard was dead because dwc3_apple and
# apple_tunable were missing). The staging adds the ones the kernel has.

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A kernel that has every module except tps6598x.
modinfo() {
  [[ $1 == -k && $3 != tps6598x ]]
}
uname() { echo 7.1.13-test; }

(
  source "$ROOT/bin/omarchy-system-btrfs-migrate"

  modules=$(usb_keyboard_modules)
  [[ $modules == *'dwc3_apple'* && $modules == *'apple_tunable'* ]] ||
    fail 'the Apple USB-C controller modules are listed' "$modules"
  [[ $modules != *tps6598x* ]] || fail 'a module the kernel lacks is left out' "$modules"
  pass 'the USB keyboard modules the kernel has are listed'

  write_usb_keyboard_dropin "$work/conf.d" 1
  dropin=$work/conf.d/20-omarchy-usb-keyboard.conf
  [[ -f $dropin ]] || fail 'encryption writes the mkinitcpio drop-in'
  [[ $(<"$dropin") == "MODULES+=("*'dwc3_apple'*")" ]] ||
    fail 'the drop-in appends the modules to MODULES' "$(cat "$dropin")"
  grep -q tps6598x "$dropin" && fail 'the drop-in omits a module the kernel lacks'
  pass 'encryption writes a MODULES drop-in'

  write_usb_keyboard_dropin "$work/plain.d" 0
  [[ ! -e $work/plain.d ]] || fail 'no encryption, no drop-in'
  pass 'no drop-in without encryption'
)
