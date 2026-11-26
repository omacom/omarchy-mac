echo "Enable UTF-8 on Apple Silicon virtual consoles"

# Fresh installs get this from the hardware leaf and from omarchy-mac-setup.
# Existing machines never re-run that step, and systemd-vconsole-setup skipped
# their consoles at boot.

[[ $(uname -m) == "aarch64" ]] || exit 0
[[ -f $OMARCHY_PATH/install/hardware/apple/fix-console-utf8.sh ]] || exit 0

sudo bash "$OMARCHY_PATH/install/hardware/apple/fix-console-utf8.sh"
