echo "Wrap Electron apps when Apple Silicon has no render GPU"


# New installs get this from install/user/hardware/apple/electron-gl.sh.
# Existing 1Password installs used a raw /usr/local/bin symlink, so Hyprland
# launched Electron without --disable-gpu and the window never mapped.

[[ -f /proc/device-tree/compatible ]] || exit 0
grep -qi apple /proc/device-tree/compatible || exit 0

if omarchy-cmd-present omarchy-cmd-electron-gl-wrap; then
  if [[ -x /usr/bin/chromium ]]; then
    omarchy-cmd-electron-gl-wrap chromium /usr/bin/chromium
  fi
  if [[ -x /opt/1Password/1password ]]; then
    omarchy-cmd-electron-gl-wrap 1password /opt/1Password/1password
  fi
fi

# shellcheck disable=SC1091
source "$OMARCHY_PATH/install/user/hardware/apple/electron-gl.sh"
