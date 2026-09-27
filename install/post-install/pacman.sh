# Configure pacman after package installation completes. Offline target package
# installs use the live ISO's offline pacman.conf until this final restore,
# which writes the platform's online repositories (install/helpers/pacman.sh).
# A Mac's image brings its keyrings, as the ISO does on x86_64; other aarch64
# platforms install Arch Linux ARM's before its repositories replace the
# offline ones, and trust every installed keyring before the first signed sync.
source "$OMARCHY_PATH/install/helpers/pacman.sh"
platform=$(omarchy-hw-platform)

if [[ $platform == "qualcomm" || $platform == "generic-aarch64" ]]; then
  omarchy-pkg-add archlinuxarm-keyring
fi

omarchy_pacman_write_template "${OMARCHY_MIRROR:-stable}" "$platform" /etc/pacman.conf /etc/pacman.d/mirrorlist

if [[ $platform == "qualcomm" || $platform == "generic-aarch64" ]]; then
  pacman-key --init
  pacman-key --populate
fi

# Wait for CUPS to own the file, the way omarchy-settings does, so pacman does
# not turn the override into a .pacnew during ISO package installation.
if [[ -f $OMARCHY_PATH/etc-overrides/cups-cups-files.conf && -f /etc/cups/cups-files.conf ]]; then
  install -m 0640 -o root -g cups "$OMARCHY_PATH/etc-overrides/cups-cups-files.conf" /etc/cups/cups-files.conf
  rm -f /etc/cups/cups-files.conf.pacnew
fi

source "$OMARCHY_INSTALL/hardware/pacman.sh"
