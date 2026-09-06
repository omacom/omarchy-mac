# Chromium/Electron need a DRM render node. Apple Silicon without AGX only
# exposes the DCP scanout device, so GPU process init fails and the app can
# stay running with no window. Wrappers live on /usr/local/bin (ahead of
# /usr/bin in PATH) so upstream omarchy-launch-* scripts stay untouched.
# Flags are chosen at launch: when a render node appears, the same wrapper
# stops passing --disable-gpu.
compatible=${OMARCHY_DEVICE_TREE_COMPATIBLE:-/proc/device-tree/compatible}

if [[ -f $compatible ]] && grep -qi apple "$compatible"; then
  if omarchy-cmd-present omarchy-cmd-electron-gl-wrap; then
    chromium_bin=${OMARCHY_CHROMIUM_BIN:-/usr/bin/chromium}
    if [[ -x $chromium_bin ]]; then
      omarchy-cmd-electron-gl-wrap chromium "$chromium_bin"
      chromium_desktop=${OMARCHY_CHROMIUM_DESKTOP:-/usr/share/applications/chromium.desktop}
      user_chromium=$HOME/.local/share/applications/chromium.desktop
      if [[ -f $chromium_desktop ]]; then
        mkdir -p "$HOME/.local/share/applications"
        sed 's|^Exec=/usr/bin/chromium|Exec=/usr/local/bin/chromium|' \
          "$chromium_desktop" >"$user_chromium"
      fi
    fi

    onepassword_bin=${OMARCHY_1PASSWORD_BIN:-/opt/1Password/1password}
    if [[ -x $onepassword_bin ]]; then
      omarchy-cmd-electron-gl-wrap 1password "$onepassword_bin"
    fi
  fi

  looknfeel=$HOME/.config/hypr/looknfeel.lua
  if ! omarchy-hw-render-gpu && [[ -f $looknfeel ]] &&
    ! grep -q 'no_hardware_cursors' "$looknfeel"; then
    cat >>"$looknfeel" <<'EOF'

-- Apple Silicon without AGX has no DRM render node. Hardware cursors never
-- appear; draw the pointer in software like the nouveau workaround.
hl.config({
  cursor = {
    no_hardware_cursors = true,
  },
})
EOF
  fi
fi
