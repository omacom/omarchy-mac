echo "Let GDK_SCALE follow the main display's scale"

# monitors.lua used to set GDK_SCALE to 2 for every display. A config still
# carrying those stock lines would keep it there, so they're commented out;
# a value the user changed stays.
monitors=~/.config/hypr/monitors.lua
if [[ -f $monitors ]] && grep -qx 'local omarchy_gdk_scale = 2' "$monitors" &&
  grep -qxF 'hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))' "$monitors"; then
  sed -i -e 's/^local omarchy_gdk_scale = 2$/-- &/' -e 's/^hl\.env("GDK_SCALE", tostring(omarchy_gdk_scale))$/-- &/' "$monitors"
fi
