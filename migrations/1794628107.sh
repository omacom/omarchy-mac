echo "Omarchy Mac is now part of Omarchy for Apple Silicon"

# The Omarchy Mac team joined Omacom. This install gets no more updates, so
# point its owner at the official version once.
url=https://github.com/omacom/omarchy/blob/quattro/manual/44-mac-support.md#coming-from-omarchy-mac
echo "Reinstall with the official Omarchy for Apple Silicon: $url"
omarchy-notification-send -u critical -t 0 \
  "Omarchy Mac is now part of Omarchy for Apple Silicon" \
  "Reinstall with the official Omarchy for Apple Silicon. Click to open the Mac support page." \
  --exec omarchy-launch-browser "$url" || true
