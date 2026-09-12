echo "Apple Silicon: make seamless-login wait for apple-drm so boot doesn't blank on simpledrm"

# Apple Silicon (Asahi) only. The shared helper is installed by the Mac upgrade
# and by normal system-path wiring, so already-completed migrations get the same
# display guard when this transition installs its SDDM drop-in.
modinfo appledrm &>/dev/null || exit 0

unit=${OMARCHY_MIGRATION_SEAMLESS_UNIT:-/etc/systemd/system/omarchy-seamless-login.service}
[[ -f $unit ]] || exit 0

dropin=${OMARCHY_MIGRATION_SEAMLESS_DROPIN_DIR:-/etc/systemd/system/omarchy-seamless-login.service.d}
if ! grep -qF /usr/bin/omarchy-system-wait-for-display "$unit" &&
   ! grep -qF /usr/bin/omarchy-system-wait-for-display "$dropin/wait-for-display.conf" 2>/dev/null; then
  sudo mkdir -p "$dropin"
  sudo tee "$dropin/wait-for-display.conf" >/dev/null <<'DROPEOF'
[Service]
ExecStartPre=/usr/bin/omarchy-system-wait-for-display
DROPEOF
  sudo systemctl daemon-reload
fi
