echo "Add lid close and open handling for Apple Silicon Macs"

# Add lid close/open handling for Apple Silicon Macs
# Disables screen and keyboard backlight on lid close, restores on lid open

MONITORS_CONF="$HOME/.config/hypr/monitors.conf"

if [ -f "$MONITORS_CONF" ]; then
  # Check if lid handling already exists
  if ! grep -q "Apple SMC power/lid events" "$MONITORS_CONF"; then
    echo "Adding lid close/open handling to monitors.conf"
    
    cat >> "$MONITORS_CONF" << 'EOF'

# disable screen on lid down
bindl = , switch:on:Apple SMC power/lid events, exec, brightnessctl -s --device=kbd_backlight set 0
bindl = , switch:on:Apple SMC power/lid events, exec, hyprctl keyword monitor "eDP-1, disable"
# reenable screen on lid up
bindl = , switch:off:Apple SMC power/lid events, exec, hyprctl keyword monitor "eDP-1, preferred, auto, auto"
bindl = , switch:off:Apple SMC power/lid events, exec, brightnessctl -r --device=kbd_backlight
EOF
  fi
fi
