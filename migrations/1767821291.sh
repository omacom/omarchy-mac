echo "Add keyboard backlight hardware key bindings for Apple Silicon Macs"

# Add keyboard backlight hardware key bindings for Apple Silicon Macs
# XF86KbdBrightnessUp/Down are the dedicated keyboard backlight keys on Mac keyboards

MEDIA_CONF="$HOME/.config/hypr/bindings/media.conf"

if [ -f "$MEDIA_CONF" ]; then
  # Check if keyboard backlight hardware keys already exist
  if ! grep -q "XF86KbdBrightnessUp" "$MEDIA_CONF"; then
    echo "Adding keyboard backlight hardware key bindings"
    
    # Add after the SHIFT+brightness lines
    if grep -q "XF86MonBrightnessDown, Keyboard backlight down" "$MEDIA_CONF"; then
      sed -i '/XF86MonBrightnessDown, Keyboard backlight down/a\
# Keyboard backlight with default backlight keys\
bindeld = , XF86KbdBrightnessDown, Keyboard backlight down, exec, brightnessctl --device=kbd_backlight set 5%-\
bindeld = , XF86KbdBrightnessUp, Keyboard backlight up, exec, brightnessctl --device=kbd_backlight set +5%' "$MEDIA_CONF"
    fi
  fi
fi
