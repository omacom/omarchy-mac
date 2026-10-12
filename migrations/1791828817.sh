echo "Map the Asahi microphone into a virtual source"

# The mapper now feeds a virtual source instead of a null sink whose monitor
# was the default input (apps that name no device recorded silence from it).
# A watcher started before this update keeps running the old code, and its
# null sink, until it is restarted; the new code retires that sink, keeps its
# gain and mute, and takes over as the default input where the monitor was.
omarchy-hw-apple || exit 0

# Without a live user manager there is no watcher to replace: the next login
# starts the packaged code.
if ! systemctl --user show-environment >/dev/null 2>&1; then
  exit 0
fi

if ! systemctl --user is-active --quiet omarchy-asahi-mic.service; then
  exit 0
fi

if ! error=$(systemctl --user restart omarchy-asahi-mic.service 2>&1); then
  echo "Could not restart omarchy-asahi-mic.service: $error"
  echo "The microphone mapping repair will be retried by omarchy-migrate."
  exit 1
fi
