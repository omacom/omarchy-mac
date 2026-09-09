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
# Units are enabled one at a time so one bad unit cannot stop the rest, but
# an unexpected failure still fails this step: omarchy-provision-first-run
# must not mark first-run done while a required unit such as sleep-lock or
# migrate-notify is missing from the session, since nothing else retries it.
#
# The single exception is omarchy-brightness-keyboard-auto.service when
# systemd reports it as not-found. That is the 4.0.2 packaging omission — a
# unit that shipped in /usr/share/omarchy but was never installed into
# /usr/lib/systemd/user/ — which no login-retry loop can fix, and which
# replayed the whole first-run notification stack at every login. Anything
# else (a transient failure of that same unit, a masked or bad-setting
# state, or an unreadable state query) is treated as a real failure so
# first-run retries.

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

failed=0
for unit in "${units[@]}"; do
  if systemctl --user enable --now "$unit"; then
    continue
  fi

  if [[ $unit == "omarchy-brightness-keyboard-auto.service" ]]; then
    if load_state=$(systemctl --user show --property=LoadState --value "$unit"); then
      if [[ $load_state == "not-found" ]]; then
        echo "Warning: skipping known missing unit $unit; install the repaired package" >&2
        continue
      fi
    fi
  fi

  echo "Error: could not enable $unit; setup must retry" >&2
  failed=1
done

exit "$failed"
