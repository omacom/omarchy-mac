echo "Add SUPER+SPACE fuzzel binding for Omarchy Mac"

# Add SUPER+SPACE fuzzel binding for Mac fork (replaces walker)
# This adds the app launcher keybinding for users who had older configs

BINDINGS_CONF="$HOME/.config/hypr/bindings.conf"

if [ -f "$BINDINGS_CONF" ]; then
  # Check if SUPER+SPACE fuzzel binding already exists
  if ! grep -q "SUPER, SPACE.*fuzzel" "$BINDINGS_CONF"; then
    echo "Adding SUPER+SPACE fuzzel launcher binding"

    # Check if there's any SUPER, SPACE binding (might be walker)
    if grep -q "SUPER, SPACE" "$BINDINGS_CONF"; then
      # Replace existing SUPER+SPACE binding with fuzzel
      sed -i 's/bindd = SUPER, SPACE,.*/bindd = SUPER, SPACE, Launch apps, exec, omarchy-launch-fuzzel/' "$BINDINGS_CONF"
    else
      # Add new binding before the omarchy-menu line
      if grep -q "SUPER ALT, SPACE, Omarchy menu" "$BINDINGS_CONF"; then
        sed -i '/SUPER ALT, SPACE, Omarchy menu/i\
# Mac-specific: Use fuzzel for launcher (original uses omarchy-launch-walker)\
bindd = SUPER, SPACE, Launch apps, exec, omarchy-launch-fuzzel' "$BINDINGS_CONF"
      else
        # Just append to the file
        echo "" >> "$BINDINGS_CONF"
        echo "# Mac-specific: Use fuzzel for launcher" >> "$BINDINGS_CONF"
        echo "bindd = SUPER, SPACE, Launch apps, exec, omarchy-launch-fuzzel" >> "$BINDINGS_CONF"
      fi
    fi
  fi
fi
