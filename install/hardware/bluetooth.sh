systemctl enable bluetooth.service

# AutoEnable stays at its stock default on purpose. It was set to false here to
# persist the power state, which it never did: BlueZ has no such behaviour, so
# all it bought was Bluetooth coming up off on every boot. omarchy-bluetooth-power
# holds the state in the rfkill soft block instead, and leaving AutoEnable alone
# is what lets bluetoothd bring the adapter back up when that block is lifted.

# FastConnectable keeps the adapter answerable to incoming pages through the
# seconds after bluetoothd starts, when paired keyboards and mice are already
# trying to come back — the same window on every resume from sleep. Only the
# exact stock line is flipped, so a hand-set value survives.
if [[ -f /etc/bluetooth/main.conf ]] && ! grep -q '^FastConnectable = true$' /etc/bluetooth/main.conf; then
  sudo sed -i 's/^#FastConnectable = false$/FastConnectable = true/' /etc/bluetooth/main.conf
fi
