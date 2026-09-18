# The Broadcom firmware on Apple Silicon Macs wedges across s2idle: scans fail
# with -52 and every association is rejected with status_code=16, which
# NetworkManager reports as a wrong password. Toggling the radio does not reset
# the chip firmware - only a driver reload clears it.
# Upstream: https://github.com/AsahiLinux/linux/issues/439
#
# Recover with omarchy-wifi-resume-fix from a service ordered after
# suspend.target, so it runs on resume without delaying it (a system-sleep
# hook would run synchronously and block every resume). The command reloads
# the driver when the wedge signature appears, or when Wi-Fi stays down past a
# short backstop, so it stays a no-op on machines and kernels where the
# firmware bug does not bite - and stops acting early by itself if the bug is
# ever fixed.
#
# BCM4378 (14e4:4425), BCM4387 (14e4:4433) and BCM4388 (14e4:4434) also appear
# in T2 Intel Macs, where suspend takes a different path - hence the
# architecture gate.
#
# BCM4388 (14e4:4434) wedges on real lid-close suspend (#10857: an M2 Pro
# wedges reliably and recovers after a manual enable). The single six-minute
# s2idle test on an M2 Max in the PR #255 review that excluded it did not
# reproduce the real-world path.

if [[ $(uname -m) == "aarch64" ]] && lspci -nn | grep -E "14e4:(4425|4433|4434)" >/dev/null; then
  echo "Detected Apple Silicon Broadcom Wi-Fi; installing resume recovery"

  cat > /etc/systemd/system/omarchy-wifi-resume-fix.service <<'EOF'
[Unit]
Description=Reload brcmfmac if Wi-Fi does not return after resume
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/bin/omarchy-wifi-resume-fix
TimeoutStartSec=120

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF

  systemctl enable omarchy-wifi-resume-fix.service
fi
