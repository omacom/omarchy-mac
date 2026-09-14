# Global launchers belong to system setup, never graphical user finalization.
compatible=${OMARCHY_DEVICE_TREE_COMPATIBLE:-/proc/device-tree/compatible}
if [[ -f $compatible ]] && grep -qi apple "$compatible"; then
  for app in chromium 1password; do
    if [[ $app == "chromium" ]]; then
      real=${OMARCHY_CHROMIUM_BIN:-/usr/bin/chromium}
    else
      real=${OMARCHY_1PASSWORD_BIN:-/opt/1Password/1password}
    fi
    if [[ -x $real ]]; then
      if omarchy-cmd-electron-gl-wrap "$app" "$real"; then
        :
      else
        status=$?
        if ((status == 3)); then
          echo "Preserving administrator-owned $app launcher" >&2
        else
          return "$status"
        fi
      fi
    fi
  done
fi
