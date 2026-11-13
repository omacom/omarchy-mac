echo "Disable hardware video decode in Chromium-family browsers"

# On Apple Silicon the VA-API path talks to the AVD decoder, which renders
# green frames on a subset of streams (#388/#370). The decoder gate in current
# Chromium is the AcceleratedVideoDecoder feature — the older
# --disable-accelerated-video-decode switch only feeds the about:gpu status
# page and is consumed nowhere on the Linux decode path.
#
# omarchy-install-browser copies config/chromium-flags.conf into each
# browser's flags file at install time, so new installs already carry this.
# Existing installs never got a re-copy: merge the feature into whatever
# *-flags.conf files are present.

for conf in "$HOME"/.config/*-flags.conf; do
  [[ -f $conf ]] || continue
  grep -q '^--disable-features=.*AcceleratedVideoDecoder' "$conf" && continue

  if grep -q '^--disable-features=' "$conf"; then
    # A second --disable-features argument would replace, not extend, the
    # existing list — merge into it instead.
    sed -i -E 's/^--disable-features=(.*)$/--disable-features=\1,AcceleratedVideoDecoder/' "$conf"
  else
    printf '%s\n' "--disable-features=AcceleratedVideoDecoder" >>"$conf"
  fi
done
