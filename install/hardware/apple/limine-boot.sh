# Apple boot policy belongs to the independently packaged boot support.
if omarchy-hw-apple-silicon; then
  source "${OMARCHY_MAC_BOOT_LIB:-/usr/lib/omarchy-mac/boot}/setup/limine-boot.sh" || return 1
fi
