echo "Recover Wi-Fi after resume on BCM4388 Apple Silicon Macs"

# Published migrations are immutable: omarchy-migrate marks completion per
# filename, so editing 1787753224.sh would never reach machines that already
# ran it. This follow-up migration adds BCM4388 (14e4:4434), whose firmware
# wedges on real lid-close suspend (#10857), to the existing repair. Machines
# already running the recovery service are left untouched by the leaf's own
# enabled check, so this is a no-op everywhere except a BCM4388 Mac that was
# excluded before.

[[ $(uname -m) == "aarch64" ]] || exit 0
# grep without -q reads all of lspci's output: this runs under pipefail, where
# an early -q exit would kill a chatty lspci with SIGPIPE and read the failed
# pipeline as "no such hardware" (#6608).
lspci -nn | grep -E "14e4:4434" >/dev/null || exit 0

# Another user on this machine may already have applied the repair.
if systemctl is-enabled --quiet omarchy-wifi-resume-fix.service 2>/dev/null; then
  exit 0
fi

sudo bash "$OMARCHY_PATH/install/hardware/apple/fix-wifi-resume.sh"