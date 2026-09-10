echo "Enable battery guard service for existing installs"

unit_name="omarchy-battery-guard.service"
unit_source="/usr/share/omarchy/default/systemd/system/$unit_name"

if systemctl is-enabled --quiet "$unit_name" 2>/dev/null && systemctl is-active --quiet "$unit_name" 2>/dev/null; then
  exit 0
fi

sudo systemctl link --force "$unit_source"
sudo systemctl daemon-reload
sudo systemctl enable --now "$unit_name"
