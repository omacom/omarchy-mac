#!/bin/bash
# Sound on Apple Silicon needs three things this install would otherwise never
# get, for three different reasons.
#
# PipeWire's PulseAudio server: install/omarchy-other.packages lists
# pipewire-pulse and says why it is not in the base set -- "Utilized by ISO
# builder to ensure package availability in the ISO". x86 machines get it from
# the ISO. A Mac has no ISO, and wireplumber pulls in pipewire but not
# pipewire-pulse, so the machine ends up with a running audio server that
# nothing can talk to: pactl says "Connection refused", and every Omarchy audio
# command exits 1 -- the volume and mute keys do nothing while brightness works
# fine, because brightness never touches PulseAudio.
#
# Realtime scheduling: rtkit is only an optional dependency of pipewire, so
# nothing here would pull it in. Without it pipewire's data threads run at
# normal priority, and any load spike delays the DSP cycle long enough to
# underrun -- heard as crackling or popping that gets worse under load. The
# Asahi speaker filter chain runs several convolvers per cycle, so it is more
# exposed to this than a plain sink.
#
# Then the Apple parts: asahi-audio carries the UCM profiles and the DSP filter
# chain that makes a speaker sink exist at all, and speakersafetyd is what
# allows the speakers to play. Without the daemon the kernel keeps them muted,
# on purpose -- these drivers can be damaged by what the hardware will happily
# ask them to do.

OMARCHY_ASAHI_AUDIO_PACKAGES_CHANGED=0

# Every device-tree machine has a compatible file, so it has to name Apple --
# otherwise a Raspberry Pi would install the Asahi stack too.
# Tests stub this via OMARCHY_UNAME_M and OMARCHY_APPLE_COMPATIBLE.
omarchy-hw-apple-silicon || return 0

# pkg-missing rather than a bare pkg-add, so the migration can tell whether this
# actually installed anything and only then ask for a reboot.
if omarchy-pkg-missing rtkit pipewire-pulse pipewire-alsa asahi-audio speakersafetyd; then
  echo "Installing the Apple Silicon audio stack"
  omarchy-pkg-add rtkit pipewire-pulse pipewire-alsa asahi-audio speakersafetyd ||
    echo "Warning: some audio packages could not be installed; sound may not work."

  # A warning rather than a failure: hardware setup runs under set -e, so failing
  # here would abort the whole install over speakers that can be fixed later.
  if omarchy-pkg-present rtkit pipewire-pulse pipewire-alsa asahi-audio speakersafetyd; then
    OMARCHY_ASAHI_AUDIO_PACKAGES_CHANGED=1
  else
    echo "Warning: the protected Asahi audio stack is incomplete; the speakers stay muted." >&2
  fi
fi

# The daemon has to be running before the speakers will produce anything.
sudo systemctl enable --now speakersafetyd >/dev/null 2>&1 ||
  echo "Warning: speakersafetyd did not start; the speakers stay muted."

# pipewire-pulse is socket-activated per user, so enabling it system-wide is not
# the job; the user units are enabled at first run.
