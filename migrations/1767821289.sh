echo "Add hyprlock to autostart for Apple Silicon Macs"

# Add hyprlock to autostart for enhanced security on Apple Silicon Macs
# This ensures the lock screen is ready immediately on boot

AUTOSTART_CONF="$HOME/.config/hypr/autostart.conf"

if [ -f "$AUTOSTART_CONF" ]; then
  # Check if hyprlock autostart already exists
  if ! grep -q "^exec-once = hyprlock" "$AUTOSTART_CONF"; then
    echo "Adding hyprlock to autostart for enhanced security"
    
    # Add hyprlock at the beginning of the file
    sed -i '1i exec-once = hyprlock' "$AUTOSTART_CONF"
  fi
fi
