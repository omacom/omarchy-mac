# tiny-dfr draws the Touch Bar keys. Its udev rules give the Touch Bar display
# and digitizer their own seat, so the compositor leaves them alone, and start
# the daemon when the Touch Bar appears. There is no service to enable.
#
# A compositor that is already running keeps the display it opened before the
# seat rule existed, so the migration that reuses this leaf on an existing
# install asks for a reboot when the flag below is set.
OMARCHY_TOUCH_BAR_PACKAGES_CHANGED=0

omarchy-hw-apple-touch-bar || return 0

if omarchy-pkg-missing tiny-dfr; then
  echo "Detected Apple Silicon Touch Bar: installing tiny-dfr"
  omarchy-pkg-add tiny-dfr ||
    echo "Warning: tiny-dfr could not be installed; the Touch Bar stays blank."

  if omarchy-pkg-present tiny-dfr; then
    OMARCHY_TOUCH_BAR_PACKAGES_CHANGED=1
  fi
fi
