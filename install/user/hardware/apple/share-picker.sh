# hyprland-preview-share-picker is in omarchy-base.packages and omarchy-aarch64.
# Older Chromium flag files still omit WebRTCPipeWireCapturer; write it on
# Apple Silicon only. Do not write this into shipped x86 defaults.
omarchy-hw-apple-silicon || return 0

# Same PipeWire capturer flag the migration writes for existing Apple Silicon
# configs. Modern Chromium enables it by default; this covers older user flag
# files on a fresh Apple Silicon install. Do not write this into shipped x86
# defaults.
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
