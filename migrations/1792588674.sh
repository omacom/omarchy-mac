echo "Enable Bluetooth FastConnectable for quicker peripheral reconnection after boot and sleep"

marker="${OMARCHY_BLUETOOTH_FASTCONNECTABLE_MARKER:-/var/lib/omarchy/migrations/1792588674}"
main_conf="${OMARCHY_BLUETOOTH_MAIN_CONF:-/etc/bluetooth/main.conf}"

# Machine-wide work, but migration completion is recorded per user, so a second
# account would run it again and re-touch the file an administrator may have
# changed in between. Written last, so an interrupted run is retried rather
# than skipped.
if [[ -e $marker ]]; then
  exit 0
fi

# bluetoothd reads main.conf only at start, so the change lands on the next
# start; restarting here would drop live audio for no urgency.
#
# Only the exact stock line is flipped, so a hand-set value survives.
if [[ -f $main_conf ]] && ! grep -q '^FastConnectable = true$' "$main_conf"; then
  sudo sed -i 's/^#FastConnectable = false$/FastConnectable = true/' "$main_conf"
fi

sudo install -Dm644 /dev/null "$marker"
