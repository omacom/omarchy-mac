# Map the Asahi beamformed mic array to a stereo source and drop the unplugged
# headset jack's session priority so apps do not pick a dead input.

omarchy-hw-apple || return 0

mkdir -p ~/.config/wireplumber/wireplumber.conf.d/
src="$OMARCHY_PATH/default/wireplumber/wireplumber.conf.d/asahi-headset-mic.conf"
dst="$HOME/.config/wireplumber/wireplumber.conf.d/asahi-headset-mic.conf"
if [[ -f $src ]]; then
  cp "$src" "$dst"
fi

omarchy-audio-asahi-mic-map >/dev/null 2>&1 || true
