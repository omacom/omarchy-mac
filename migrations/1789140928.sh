echo "Apple Silicon: enable PipeWire capture for the browser screen-share picker"

omarchy-hw-apple-silicon || exit 0

# Chromium/Brave only reach the picker when they use the PipeWire capturer.
for conf in ~/.config/{chromium,brave,chrome,microsoft-edge-stable}-flags.conf; do
  [[ -f $conf ]] || continue
  grep -q 'WebRTCPipeWireCapturer' "$conf" && continue
  if grep -q -- '--enable-features=' "$conf"; then
    sed -i 's/\(^--enable-features=[^[:space:]]*\)/\1,WebRTCPipeWireCapturer/' "$conf"
  else
    [[ -n $(tail -c1 "$conf") ]] && echo >>"$conf"
    echo '--enable-features=WebRTCPipeWireCapturer' >>"$conf"
  fi
done
