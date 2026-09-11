echo "Enable hardware video decode on Apple Silicon"

# Fresh installs run this leaf from omarchy-apply-hardware. Reuse it here so
# existing installs get the same hardware gate and package set. The package
# check makes this safe when another user has already set the machine up.
video_setup="$OMARCHY_PATH/install/hardware/apple/video-decode.sh"
[[ -f $video_setup ]] || exit 0

source "$video_setup"

# The apple-avd driver requests its firmware once, when it probes at boot, and
# gives up when the file is not there. Installing the firmware under a running
# kernel therefore changes nothing until the driver probes again, so a reboot
# is what actually turns the decoder on.
if (( ${OMARCHY_AVD_PACKAGES_CHANGED:-0} )); then
  omarchy-state set reboot-required
fi
