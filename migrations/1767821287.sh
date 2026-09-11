echo "Add keyboard backlight dimming on idle for Apple Silicon Macs"

# Add keyboard backlight dimming on idle (Mac-specific)
# This turns off the keyboard backlight when the screen goes off and restores it on resume

HYPRIDLE_CONF="$HOME/.config/hypr/hypridle.conf"

if [ -f "$HYPRIDLE_CONF" ]; then
  # Check if keyboard backlight listener already exists
  if ! grep -q "kbd_backlight" "$HYPRIDLE_CONF"; then
    echo "Adding keyboard backlight idle control to hypridle.conf"
    
    # Add the keyboard backlight listener before the DPMS off listener
    sed -i '/timeout = 330.*# 5.5min/i\
listener {\
    timeout = 330\
    on-timeout = brightnessctl -s --device=kbd_backlight set 0 # saves state then turns off keyboard backlight\
    on-resume = brightnessctl -r --device=kbd_backlight        # state gets saved explicitly so it has to be restored explicitly\
    }\
' "$HYPRIDLE_CONF"
  fi
fi
