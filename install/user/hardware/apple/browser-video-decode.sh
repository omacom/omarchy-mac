# Chromium-family browsers built with VA-API, such as Brave, pick up the AVD
# decoder through libva-v4l2_request-avd and render green frames on some
# streams. AcceleratedVideoDecoder is the feature that gates hardware decode on
# Linux, so turn it off in each browser's flags: browsers decode in software
# while mpv, ffmpeg and GStreamer keep AVD. A second --disable-features argument
# would replace the first rather than add to it, so the feature joins an
# existing list.
#
# Runs for each user at setup, from the migration on existing installs, and
# from omarchy-install-browser after it writes a fresh flags file.
omarchy-hw-apple-silicon || return 0

for conf in ~/.config/{chromium,chrome,microsoft-edge-stable,brave,brave-origin}-flags.conf; do
  [[ -f $conf ]] || continue
  if grep -q -- '^--disable-features=' "$conf"; then
    sed -i -E '/^--disable-features=/{/[=,]AcceleratedVideoDecoder([,[:space:]]|$)/!s/^(--disable-features=[^[:space:]]*)/\1,AcceleratedVideoDecoder/;s/^--disable-features=,/--disable-features=/}' "$conf"
  else
    [[ -n $(tail -c1 "$conf") ]] && echo >>"$conf"
    echo '--disable-features=AcceleratedVideoDecoder' >>"$conf"
  fi
done
