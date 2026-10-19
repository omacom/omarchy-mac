echo "Install the Touch Bar daemon on Apple Silicon MacBook Pros"

# Fresh installs run this leaf from omarchy-apply-hardware. Reuse it here so
# existing installs get the same hardware gate. The package check makes this
# safe when another user has already set the machine up.
touch_bar_setup="$OMARCHY_PATH/install/hardware/apple/touch-bar.sh"
[[ -f $touch_bar_setup ]] || exit 0

source "$touch_bar_setup"

if (( ${OMARCHY_TOUCH_BAR_PACKAGES_CHANGED:-0} )); then
  omarchy-state set reboot-required
fi
