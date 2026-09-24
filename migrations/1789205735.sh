echo "Enable the restored package-owned keyboard backlight service"

# The original migration (1788139121) could complete with a dangling wants
# symlink because omarchy-settings omitted this unit. Recheck the delivered
# package before repairing existing users; first-run handles new users.
unit=omarchy-brightness-keyboard-auto.service
unit_path="/usr/lib/systemd/user/$unit"
if [[ ! -f $unit_path ]]; then
  echo "Missing $unit_path; update omarchy-settings before retrying this migration." >&2
  exit 1
fi

wants_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/graphical-session.target.wants"
if [[ -e $wants_dir/$unit || -L $wants_dir/$unit ]]; then
  # Only the original absolute package link belongs to this repair. Enabling
  # through systemctl can replace a deliberate custom link or regular file.
  if [[ ! -L $wants_dir/$unit ]] || [[ $(readlink "$wants_dir/$unit") != "$unit_path" ]]; then
    echo "Preserving the existing custom keyboard backlight service entry."
    exit 0
  fi
fi

user_manager_socket="${XDG_RUNTIME_DIR:-/run/user/$UID}/systemd/private"
if ! systemctl --user show-environment >/dev/null 2>&1; then
  if [[ -S $user_manager_socket ]]; then
    echo "Cannot reach the running user service manager; retry this migration after reconnecting." >&2
    exit 1
  fi
  # No manager is running (for example, an offline update). Preserve existing
  # links and overrides; the next manager loads the newly delivered unit.
  mkdir -p "$wants_dir"
  if [[ ! -e $wants_dir/$unit && ! -L $wants_dir/$unit ]]; then
    ln -s "$unit_path" "$wants_dir/$unit"
  fi
else
  # A failed operation must leave the migration pending, just as a failed
  # first-run step must leave setup retryable. ExecCondition handles machines
  # without an ambient light sensor or keyboard backlight.
  systemctl --user daemon-reload
  # A user may deliberately mask this optional feature. Keep that choice
  # without blocking the migration queue; other inspection failures still fail.
  if ! unit_state=$(systemctl --user is-enabled "$unit"); then
    case "$unit_state" in
      disabled | masked | masked-runtime) ;;
      *)
        echo "Could not inspect the keyboard backlight service; retry this migration." >&2
        exit 1
        ;;
    esac
  fi
  if [[ $unit_state == "masked" || $unit_state == "masked-runtime" ]]; then
    echo "Preserving the masked keyboard backlight service."
    exit 0
  fi
  systemctl --user enable "$unit"
  graphical_state=$(systemctl --user show --property=ActiveState --value graphical-session.target)
  if [[ $graphical_state == "active" ]]; then
    systemctl --user start "$unit"
  fi
fi
