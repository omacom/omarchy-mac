#!/bin/bash

# Enable AND start the user systemd units we ship. Runs at first-run rather
# than at finalize-user time because the user manager isn't live during the
# ISO chroot — by first-run, the Hyprland/uwsm session is up and
# `systemctl --user enable --now` both writes the correct .wants symlinks
# (based on each unit's [Install]/WantedBy) and starts the services so the
# first session has bluetooth pairing, sleep lock, etc. live immediately
# instead of waiting for the next login. ConditionPath* in the unit files
# keep the enabled units inert on hardware they don't apply to.
#
# Units are enabled one at a time, and a per-unit failure is reported but
# does not fail this step. Failing the step would keep omarchy-provision-
# first-run from marking first-run done, replaying the whole first-run
# notification stack at every login — the 4.0.2 loop caused by a unit that
# shipped in /usr/share/omarchy but was never packaged into
# /usr/lib/systemd/user/. A unit systemd cannot enable is a packaging bug
# that a login-retry loop cannot fix.

set -euo pipefail

units=(
  bt-agent.service
  omarchy-recover-internal-monitor.service
  omarchy-sleep-lock.service
  omarchy-migrate-notify.service
  omarchy-fcitx5.service
  omarchy-crash-watch.service
  omarchy-brightness-keyboard-auto.service
)

systemctl --user daemon-reload

for unit in "${units[@]}"; do
  if ! systemctl --user enable --now "$unit"; then
    echo "Warning: could not enable $unit" >&2
  fi
done
