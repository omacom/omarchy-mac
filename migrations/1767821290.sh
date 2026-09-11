echo "Update windowrule syntax for Hyprland 0.53+"

# Update windowrule syntax for Hyprland 0.53+
# Changes scrolltouchpad -> scroll_touchpad and class: -> match:class
# See: https://wiki.hypr.land/Configuring/Window-Rules/

INPUT_CONF="$HOME/.config/hypr/input.conf"

if [ -f "$INPUT_CONF" ]; then
  # Check if old syntax exists
  if grep -q "scrolltouchpad" "$INPUT_CONF"; then
    echo "Updating windowrule syntax for Hyprland 0.53+"
    
    # Update scrolltouchpad to scroll_touchpad and class: to match:class
    sed -i 's/windowrule = scrolltouchpad \([0-9.]*\), class:\(.*\)/windowrule = scroll_touchpad \1, match:class \2/g' "$INPUT_CONF"
  fi
fi

# Update app config files in user's hypr directory
for conf in "$HOME"/.config/hypr/apps/*.conf; do
  if [ -f "$conf" ]; then
    # Fix windowrule/windowrulev2 syntax: class: -> match:class, title: -> match:title
    if grep -qE "windowrule.*class:|windowrule.*title:" "$conf"; then
      echo "Updating windowrule syntax in $(basename "$conf")"
      sed -i 's/\(windowrulev\?2\? = [^,]*, \)class:/\1match:class /g' "$conf"
      sed -i 's/\(windowrulev\?2\? = [^,]*, \)title:/\1match:title /g' "$conf"
    fi
  fi
done
