echo "Install the reliable resume kernel for Apple BCM43602 Wi-Fi"

# Fresh installations run this hardware-gated leaf during system setup. Reuse
# it here so existing installations receive the same package and boot policy.
# Detection happens before elevation and is repeated inside the privileged leaf.
omarchy-hw-apple-bcm43602 || exit 0
omarchy-hw-apple-bcm43602 --ready && exit 0

sudo bash -euo pipefail "$OMARCHY_PATH/install/hardware/apple/install-bcm43602-kernel.sh"
omarchy-hw-apple-bcm43602 --ready
omarchy-state set reboot-required
