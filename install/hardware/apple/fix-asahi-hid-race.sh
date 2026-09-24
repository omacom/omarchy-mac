#!/bin/bash

# Apple Silicon (Asahi): the internal keyboard/trackpad HID devices from
# dockchannel-hid first bind to hid-generic, then get destroyed and re-created
# once hid_apple/hid_magicmouse load. That churn reshuffles the input event
# minors while udev, logind, and the compositor are starting; on unlucky boots
# logind's TakeDevice fails for the trackpad node (libseat "Couldn't open
# device") and libinput never retries, leaving the trackpad dead for the whole
# session. Loading the drivers from the initramfs makes the devices bind
# correctly on first registration, so the churn never happens.
# See docs/apple-silicon-trackpad.md.
if [[ $(uname -m) == "aarch64" ]] && grep -qai apple /proc/device-tree/compatible 2>/dev/null; then
  echo "Detected Apple Silicon Mac: early-loading Apple HID modules"
  sudo mkdir -p /etc/mkinitcpio.conf.d
  sudo tee /etc/mkinitcpio.conf.d/apple_hid_modules.conf >/dev/null <<'EOF'
# mkinitcpio fails the whole image over a MODULES entry it cannot find, so name
# each driver only on kernels that build it as a module. Ending on unset keeps
# the exit status zero, which mkinitcpio reads as a readable config.
for _omarchy_apple_hid_module in hid_apple hid_magicmouse; do
  modinfo -k "${KERNELVERSION:-$(uname -r)}" "$_omarchy_apple_hid_module" >/dev/null 2>&1 &&
    MODULES+=("$_omarchy_apple_hid_module")
done
unset _omarchy_apple_hid_module
EOF
fi
