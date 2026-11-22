echo "Apply Apple Silicon MTP trackpad and keyboard quirks"

# Fresh installs get the libinput override from the hardware leaf; run the
# same leaf here for existing installs. It replaces only its managed block and
# preserves administrator overrides after it.

[[ $(uname -m) == "aarch64" ]] || exit 0
[[ -f /proc/device-tree/compatible ]] || exit 0
grep -Faiq 'apple,' /proc/device-tree/compatible || exit 0

sudo bash "$OMARCHY_PATH/install/hardware/apple/fix-mtp-trackpad.sh"
