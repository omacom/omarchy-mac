echo "Enable Wi-Fi resume recovery on Apple Silicon Macs with BCM4388"

# A failed detector or lspci keeps the migration pending instead of skipping it.
platform=$(omarchy-hw-platform)
[[ $platform == "apple-silicon" ]] || exit 0
devices=$(lspci -nn)
grep -E '14e4:4434' <<<"$devices" >/dev/null || exit 0

omarchy-setup-mac --system
# Setup skips the chip when the installed add-on predates it; stay pending until it doesn't.
if ! /usr/lib/omarchy-mac/wifi-supported; then
  echo "Error: the installed omarchy-mac does not cover BCM4388 yet; update again to finish." >&2
  exit 1
fi
