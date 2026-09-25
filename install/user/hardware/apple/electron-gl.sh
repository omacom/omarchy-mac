# Chromium/Electron need a DRM render node. Apple Silicon without AGX only
# exposes the DCP scanout device, so GPU process init fails and the app can
# stay running with no window. Wrappers live on /usr/local/bin (ahead of
# /usr/bin in PATH) so upstream omarchy-launch-* scripts stay untouched.
# Flags are chosen at launch: when a render node appears, the same wrapper
# stops passing --disable-gpu.
omarchy-hw-apple-silicon || return 0

for app in chromium 1password cursor; do
  if [[ $app == "chromium" ]]; then
    real=${OMARCHY_CHROMIUM_BIN:-/usr/bin/chromium}
    vendor=${OMARCHY_CHROMIUM_DESKTOP:-/usr/share/applications/chromium.desktop}
  elif [[ $app == "1password" ]]; then
    real=${OMARCHY_1PASSWORD_BIN:-/opt/1Password/1password}
    vendor=${OMARCHY_1PASSWORD_DESKTOP:-/usr/share/applications/1password.desktop}
  else
    real=${OMARCHY_CURSOR_BIN:-/usr/bin/cursor}
    vendor=${OMARCHY_CURSOR_DESKTOP:-/usr/share/applications/cursor.desktop}
  fi
  if [[ -x $real ]]; then
    if omarchy-cmd-electron-gl-wrap --check "$app" "$real"; then
      omarchy-cmd-desktop-exec-repair "$HOME/.local/share/applications/$app.desktop" \
        "$vendor" "${OMARCHY_ELECTRON_GL_BIND_DIR:-/usr/local/bin}/$app" "$real" "$app"
      if [[ $app == cursor ]]; then
        omarchy-cmd-desktop-exec-repair "$HOME/.local/share/applications/cursor-url-handler.desktop" \
          /usr/share/applications/cursor-url-handler.desktop \
          "${OMARCHY_ELECTRON_GL_BIND_DIR:-/usr/local/bin}/cursor" "$real" cursor
      fi
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
