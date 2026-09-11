# Chromium/Electron need a DRM render node. Apple Silicon without AGX only
# exposes the DCP scanout device, so GPU process init fails and the app can
# stay running with no window. Wrappers live on /usr/local/bin (ahead of
# /usr/bin in PATH) so upstream omarchy-launch-* scripts stay untouched.
# Flags are chosen at launch: when a render node appears, the same wrapper
# stops passing --disable-gpu.
compatible=${OMARCHY_DEVICE_TREE_COMPATIBLE:-/proc/device-tree/compatible}

if [[ -f $compatible ]] && grep -qi apple "$compatible"; then
  for app in chromium 1password; do
    if [[ $app == "chromium" ]]; then
      real=${OMARCHY_CHROMIUM_BIN:-/usr/bin/chromium}
      vendor=${OMARCHY_CHROMIUM_DESKTOP:-/usr/share/applications/chromium.desktop}
    else
      real=${OMARCHY_1PASSWORD_BIN:-/opt/1Password/1password}
      vendor=${OMARCHY_1PASSWORD_DESKTOP:-/usr/share/applications/1password.desktop}
    fi
    if [[ -x $real ]]; then
      if omarchy-cmd-electron-gl-wrap --check "$app" "$real"; then
        omarchy-cmd-desktop-exec-repair "$HOME/.local/share/applications/$app.desktop" \
          "$vendor" "${OMARCHY_ELECTRON_GL_BIND_DIR:-/usr/local/bin}/$app" "$real" "$app"
      else
        status=$?
        if ((status == 3 || status == 4)); then
          echo "Skipping $app desktop repair: managed wrapper is not ready" >&2
        else
          return "$status"
        fi
      fi
    fi
  done

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
