echo "Drive keyboard backlight from the ambient light sensor"

# Existing installs never run first-run again, so they would keep a dark
# keyboard in a dark room until someone discovered Shift+F1. Enable the
# package-owned unit; ExecCondition makes this a no-op on machines with no
# ALS or no keyboard backlight LED. Do not copy into ~/.config/systemd/user —
# quattro retires that path so /usr/lib/systemd/user/ stays authoritative.

systemctl --user daemon-reload >/dev/null 2>&1 || true

# `systemctl enable` needs a live user manager, which an update from a TTY does
# not have, so fall back to writing the symlink it would have written.
if ! systemctl --user enable omarchy-brightness-keyboard-auto.service >/dev/null 2>&1; then
  wants_dir="$HOME/.config/systemd/user/graphical-session.target.wants"
  mkdir -p "$wants_dir"
  ln -sfn /usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service \
    "$wants_dir/omarchy-brightness-keyboard-auto.service"
fi

if systemctl --user is-active --quiet graphical-session.target; then
  systemctl --user start omarchy-brightness-keyboard-auto.service >/dev/null 2>&1 || true
fi
