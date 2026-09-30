echo "Hold SDDM until appledrm is ready on Apple Silicon Macs"

# With an HDMI monitor attached at boot, appledrm can register after SDDM
# autologin has started Hyprland on simpledrm, which leaves a black screen.
# Fresh installs get the SDDM drop-in from the hardware leaf; run the same
# leaf here for existing installs.

[[ $(uname -m) == "aarch64" ]] || exit 0
grep -qi apple /proc/device-tree/compatible 2>/dev/null || exit 0

# Another user on this machine may already have applied the repair.
[[ -f /etc/systemd/system/sddm.service.d/wait-appledrm.conf ]] && exit 0

sudo bash "$OMARCHY_PATH/install/hardware/apple/fix-appledrm-login-race.sh"
sudo systemctl daemon-reload
