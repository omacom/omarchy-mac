# The Broadcom Bluetooth firmware on Apple Silicon Macs wedges across s2idle:
# on resume the controller stops answering HCI commands, every opcode fails
# with -110, and neither the bar toggle nor bluetoothctl can power it back on.
# Only unbinding and rebinding the PCIe driver clears it.
# Upstream: https://github.com/AsahiLinux/linux/issues/604
#
# Recover with omarchy-bluetooth-resume-fix from a service ordered after
# suspend.target, so it runs on resume without delaying it - the same shape
# fix-wifi-resume.sh uses for the Wi-Fi half of the same chip. The command
# rebinds only once the tx timeout signature appears, so it stays a no-op on
# machines and kernels where the firmware bug does not bite, and stops acting
# by itself if the bug is ever fixed.
#
# BCM4378 (14e4:5f69) is verified: an M1 MacBook Air wedged on resume, and the
# rebind recovered the controller without a reboot. BCM4387 (14e4:5f71) is the
# same failure reported on M2 Airs in #338 and #302.
#
# BCM4388 (14e4:5f72) is deliberately absent, not an oversight: the only
# report on that part is the rfkill path fixed in #380 (upstream
# AsahiLinux/linux#609), with nothing showing it wedging across resume on its
# own.

if [[ $(uname -m) == "aarch64" ]] && lspci -nn | grep -E "14e4:(5f69|5f71)" >/dev/null; then
  echo "Detected Apple Silicon Broadcom Bluetooth; installing resume recovery"

  cat > /etc/systemd/system/omarchy-bluetooth-resume-fix.service <<'EOF'
[Unit]
Description=Rebind hci_bcm4377 if Bluetooth wedges across resume
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
After=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/bin/omarchy-bluetooth-resume-fix
TimeoutStartSec=120

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF

  systemctl enable omarchy-bluetooth-resume-fix.service
fi
