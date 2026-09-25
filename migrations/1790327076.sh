echo "Enable Wi-Fi resume recovery on Apple Silicon Macs with BCM4388"

omarchy-hw-apple-silicon || exit 0
# grep without -q reads all of lspci's output; see migrations/1789140994.sh.
lspci -nn | grep -E '14e4:4434' >/dev/null || exit 0

omarchy-setup-mac --system
# Setup skips the chip when the installed add-on predates it; stay pending until it doesn't.
if ! /usr/lib/omarchy-mac/wifi-supported; then
  echo "Error: the installed omarchy-mac does not cover BCM4388 yet; update again to finish." >&2
  exit 1
fi
