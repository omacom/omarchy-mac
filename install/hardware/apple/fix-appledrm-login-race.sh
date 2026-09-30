# Apple Silicon: appledrm registers its DRM device only after every DCP it
# drives has booted, and until then the only display is the firmware
# framebuffer (simpledrm). With an HDMI monitor attached, bringing up the
# external DCP and the DP-to-HDMI converter pushes that registration past the
# point where SDDM autologin starts Hyprland. Hyprland then opens simpledrm,
# appledrm removes it a moment later, and the session is left on a dead device:
# black screens until reboot. Hold SDDM until the appledrm card exists. The
# wait returns at once when the card is already there and gives up after 15 s,
# so a machine without appledrm still reaches the login.
compatible=${OMARCHY_DEVICE_TREE_COMPATIBLE:-/proc/device-tree/compatible}
if [[ $(uname -m) == "aarch64" && -f $compatible ]] && grep -qi apple "$compatible"; then
  echo "Detected Apple Silicon Mac: holding SDDM until appledrm is ready"

  dropin_dir=${OMARCHY_SDDM_DROPIN_DIR:-/etc/systemd/system/sddm.service.d}
  mkdir -p "$dropin_dir"
  cat >"$dropin_dir/wait-appledrm.conf" <<'CONF'
# Start the greeter and the autologin session on appledrm, not on the
# simpledrm framebuffer it replaces (install/hardware/apple/fix-appledrm-login-race.sh).
[Service]
ExecStartPre=-/usr/bin/udevadm wait --timeout=15 /dev/dri/by-path/platform-soc:display-subsystem-card
CONF
fi
