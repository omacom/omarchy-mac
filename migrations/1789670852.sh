echo "Recover Bluetooth after resume on Apple Silicon Macs"

# The Broadcom Bluetooth firmware on Apple Silicon Macs (BCM4378/BCM4387) can
# wedge across s2idle, leaving the controller deaf to every HCI command until
# the driver is rebound (#338, upstream AsahiLinux/linux#604). Fresh installs
# get the recovery service from the hardware leaf; run the same leaf here for
# existing installs.

[[ $(uname -m) == "aarch64" ]] || exit 0
# grep without -q reads all of lspci's output: this runs under pipefail, where
# an early -q exit would kill a chatty lspci with SIGPIPE and read the failed
# pipeline as "no such hardware" (#6608).
lspci -nn | grep -E "14e4:(5f69|5f71)" >/dev/null || exit 0

# Another user on this machine may already have applied the repair.
if systemctl is-enabled --quiet omarchy-bluetooth-resume-fix.service 2>/dev/null; then
  exit 0
fi

sudo bash "$OMARCHY_PATH/install/hardware/apple/fix-bluetooth-resume.sh"
