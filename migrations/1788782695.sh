echo "Repair first-run wedged by unpackaged user units"

# 4.0.2 shipped omarchy-brightness-keyboard-auto.service and
# omarchy-speaker-tuning.service under /usr/share/omarchy without installing
# them to /usr/lib/systemd/user/, so first-run's enable step failed at every
# login and never marked itself done, and migration 1788139121's fallback
# wrote a dangling graphical-session.target.wants symlink. The package now
# installs every default/systemd/user unit; drop any dangling wants symlink
# and re-run the (now per-unit, non-wedging) enable so the units come up
# without waiting for another login.

# The repair needs a live user manager. From a TTY or SSH update there is
# nothing to enable against, so stay pending and let the login notifier
# bring the user back to omarchy-migrate inside a graphical session.
if ! systemctl --user daemon-reload >/dev/null 2>&1; then
  echo "No user systemd manager available; run omarchy-migrate again from a graphical session" >&2
  exit 1
fi

wants_dir="$HOME/.config/systemd/user/graphical-session.target.wants"
if [[ -d $wants_dir ]]; then
  for wants_link in "$wants_dir"/*.service; do
    if [[ -L $wants_link && ! -e $wants_link ]]; then
      rm -f "$wants_link"
    fi
  done
fi

bash "$OMARCHY_PATH/install/user/first-run/enable-user-units.sh"
