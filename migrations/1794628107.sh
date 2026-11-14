echo "Omarchy Mac is no longer maintained"

# The Omarchy Mac team joined Omacom. This install gets no more updates, so
# point its owner at the official version once.
url=https://omarchy.org/manual/mac-support/
echo "Reinstall with the official Omarchy for Apple Silicon: $url"
omarchy-notification-send -u critical -t 0 \
  "Omarchy Mac is no longer maintained" \
  "Reinstall with the official Omarchy for Apple Silicon. Click to open the Mac manual." \
  --exec omarchy-launch-browser "$url" || true
