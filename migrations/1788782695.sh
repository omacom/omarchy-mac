echo "Repair first-run wedged by unpackaged user units"

# 4.0.2 shipped omarchy-brightness-keyboard-auto.service and
# omarchy-speaker-tuning.service under /usr/share/omarchy without installing
# them to /usr/lib/systemd/user/, so first-run's enable step failed at every
# login and never marked itself done, and migration 1788139121's fallback
# wrote a dangling graphical-session.target.wants symlink. The package now
# installs every default/systemd/user unit; drop that one link when it still
# points at the target 1788139121 wrote and nothing is there, then re-run the
# per-unit enable so the units come up without waiting for another login.
#
# Only that exact link and target are removed: other dangling links in the
# same directory belong to the user, and a link of the same name pointing
# somewhere else is the user's own choice. The enable helper's status is
# propagated, so a required unit that cannot be enabled leaves this
# migration pending and it is retried.

# The repair needs a live user manager. From a TTY or SSH update there is
# nothing to enable against, so stay pending and let the login notifier
# bring the user back to omarchy-migrate inside a graphical session.
if ! systemctl --user daemon-reload >/dev/null 2>&1; then
  echo "No user systemd manager available; run omarchy-migrate again from a graphical session" >&2
  exit 1
fi

wants_link="$HOME/.config/systemd/user/graphical-session.target.wants/omarchy-brightness-keyboard-auto.service"
legacy_target="/usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service"
if [[ -L $wants_link && ! -e $wants_link ]]; then
  if [[ $(readlink "$wants_link") == "$legacy_target" ]]; then
    rm -- "$wants_link"
  fi
fi

bash "$OMARCHY_PATH/install/user/first-run/enable-user-units.sh"
