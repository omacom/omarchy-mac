# One-shot AirPods battery probe for the bluetooth panel, run as:
#
#   python3 airpods-battery.py AA:BB:CC:DD:EE:FF
#
# AirPods push battery over Apple's proprietary AAP protocol on an L2CAP
# channel (UUID 74ec2172-...), which no BlueZ D-Bus surface exposes. This
# script opens that channel once: it registers the profile, asks BlueZ to
# connect it to a connected device, performs the AAP handshake, requests
# notifications, and prints the first battery report as JSON. It exits
# straight after, leaving no state and no daemon — the bluetooth panel runs
# it on the same poll cadence it uses for the sysfs keyboard probe.
#
# Prints one JSON line on success, exits 1 quietly when the channel yields
# no battery report. `--self-test` runs the frame parser on hex messages for
# the shell test suite without touching Bluetooth.
#
# AAP protocol from https://github.com/maniacx/Bluetooth-Battery-Meter
#

import json
import os
import signal
import socket
import sys
import threading
import time

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

AIRPODS_UUID = "74ec2172-0bad-4d01-8f77-997b2be0722a"
PROFILE_PATH = "/com/omarchy/airpods/profile"

HANDSHAKE = bytes([
    0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
])
REQUEST_NOTIFICATIONS = bytes([
    0x04, 0x00, 0x04, 0x00, 0x0f, 0x00, 0xff, 0xff, 0xff, 0xff,
])
BATTERY_PREFIX = bytes([0x04, 0x00, 0x04, 0x00, 0x04, 0x00])
TYPE_RIGHT = 0x02
TYPE_LEFT = 0x04
TYPE_CASE = 0x08

# The panel restarts this probe on its 5s tick while no result has landed,
# so a probe must finish before the next tick. 6s covers bluez ConnectProfile
# racing plus the handshake pause plus the first notification push.
TOTAL_DEADLINE = 6.0

COMPONENTS = {
    TYPE_LEFT: "left",
    TYPE_RIGHT: "right",
    TYPE_CASE: "case",
}


def parse_battery_message(data):
    """Decode one AAP battery status message into a {part: level} mapping.

    Returns None when the message is not a battery status push. Each level is
    0-100 or None (out of range or reported gone). A component the AirPods do
    not include stays None — the panel prints only what the device answered.
    """
    if len(data) < 12 or data[:6] != BATTERY_PREFIX:
        return None
    count = data[6]
    if count < 1 or count > 3:
        return None

    levels = {"left": None, "right": None, "case": None}
    answered = False
    pos = 7
    for _ in range(count):
        if pos + 5 > len(data):
            break
        kind, _, raw, status = data[pos], data[pos + 1], data[pos + 2], data[pos + 3]
        name = COMPONENTS.get(kind)
        if name is not None:
            gone = (status & 0x04) != 0
            levels[name] = None if raw > 100 or gone else raw
            answered = answered or levels[name] is not None
        pos += 5

    return levels if answered else None


def emit(address, levels):
    print(json.dumps({
        "address": address,
        "left": levels["left"], "right": levels["right"], "case": levels["case"],
    }, separators=(",", ":")), flush=True)


def run_self_test(hex_message):
    try:
        data = bytes.fromhex(hex_message)
    except ValueError:
        print("self-test argument is not hex: %s" % hex_message, file=sys.stderr)
        return 2
    levels = parse_battery_message(data)
    if levels is None:
        print(json.dumps({"error": "not a battery message"},
                         separators=(",", ":")), flush=True)
        return 1
    emit("SELF-TEST", levels)
    return 0


class ProfileServer:
    """Profile1 object BlueZ delivers the AAP channel fd through."""

    def __init__(self, bus):
        self.bus = bus
        self.reg_id = 0
        self.levels = None
        self.done = threading.Event()
        self.iface = Gio.DBusNodeInfo.new_for_xml("""
<node>
  <interface name="org.bluez.Profile1">
    <method name="Release"/>
    <method name="NewConnection">
      <arg type="o" name="device" direction="in"/>
      <arg type="h" name="fd" direction="in"/>
      <arg type="a{sv}" name="fd_properties" direction="in"/>
    </method>
    <method name="RequestDisconnection">
      <arg type="o" name="device" direction="in"/>
    </method>
  </interface>
</node>""").interfaces[0]

    def register(self):
        self.reg_id = self.bus.register_object(
            PROFILE_PATH, self.iface, self.on_method_call, None, None)
        proxy = Gio.DBusProxy.new_sync(
            self.bus, Gio.DBusProxyFlags.NONE, None,
            "org.bluez", "/org/bluez", "org.bluez.ProfileManager1", None)
        proxy.call_sync(
            "RegisterProfile",
            GLib.Variant.new_tuple(
                GLib.Variant("o", PROFILE_PATH),
                GLib.Variant("s", AIRPODS_UUID),
                GLib.Variant("a{sv}", {
                    "Name": GLib.Variant("s", "Omarchy AirPods Battery"),
                    "Role": GLib.Variant("s", "client"),
                    "AutoConnect": GLib.Variant("b", True),
                })), Gio.DBusCallFlags.NONE, -1, None)

    def unregister(self):
        try:
            proxy = Gio.DBusProxy.new_sync(
                self.bus, Gio.DBusProxyFlags.NONE, None,
                "org.bluez", "/org/bluez", "org.bluez.ProfileManager1", None)
            proxy.call_sync(
                "UnregisterProfile",
                GLib.Variant.new_tuple(GLib.Variant("o", PROFILE_PATH)),
                Gio.DBusCallFlags.NONE, -1, None)
        except Exception:
            pass
        if self.reg_id:
            self.bus.unregister_object(self.reg_id)
            self.reg_id = 0

    def on_method_call(self, conn, sender, path, iface, method, params, invocation):
        if method == "NewConnection":
            _, fd_index, _ = params.unpack()
            fd = invocation.get_message().get_unix_fd_list().get(fd_index)
            threading.Thread(
                target=self.read_channel, args=(fd,), daemon=True).start()
        elif method == "RequestDisconnection":
            # The headset closed the data channel; nothing more to report.
            if not self.done.is_set():
                self.done.set()
        invocation.return_value(None)

    def read_channel(self, fd):
        owned = os.dup(fd)
        sock = socket.socket(fileno=owned)
        sock.settimeout(4.0)
        try:
            sock.sendall(HANDSHAKE)
            time.sleep(0.3)
            sock.sendall(REQUEST_NOTIFICATIONS)
            while True:
                data = sock.recv(1024)
                if not data:
                    break
                levels = parse_battery_message(data)
                if levels is not None:
                    self.levels = levels
                    self.done.set()
                    break
        except Exception as error:
            sys.stderr.write("airpods-battery.py: channel: %s\n" % error)
        finally:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            sock.close()


def connect_profile(bus, device_path):
    """Ask BlueZ to bring the AAP channel up; tolerate bluez-side races."""
    proxy = Gio.DBusProxy.new_sync(
        bus, Gio.DBusProxyFlags.NONE, None,
        "org.bluez", device_path, "org.bluez.Device1", None)
    for attempt in range(3):
        try:
            proxy.call_sync(
                "ConnectProfile",
                GLib.Variant.new_tuple(GLib.Variant("s", AIRPODS_UUID)),
                Gio.DBusCallFlags.NONE, 2500, None)
            return
        except Exception as error:
            text = str(error)
            if "InProgress" in text or "busy" in text:
                if attempt == 2:
                    sys.stderr.write("airpods-battery.py: connect: %s\n" % text)
                time.sleep(1.0 + attempt)
            else:
                sys.stderr.write("airpods-battery.py: connect: %s\n" % text)
                return


def run_probe(mac):
    if not mac:
        print("usage: airpods-battery.py <MAC>", file=sys.stderr)
        return 2
    device_path = "/org/bluez/hci0/dev_" + mac.replace(":", "_")

    try:
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    except Exception as error:
        sys.stderr.write("airpods-battery.py: bus: %s\n" % error)
        return 1

    server = ProfileServer(bus)
    loop = GLib.MainLoop()

    def finish():
        if not server.done.is_set():
            sys.stderr.write("airpods-battery.py: no battery report from %s\n" % mac)
        loop.quit()
        return False

    # Probe duration cap: the panel restarts us every 5s while probing, so a
    # straggler must not outlive the next tick.
    GLib.timeout_add(int(TOTAL_DEADLINE * 1000), finish)
    signal.signal(signal.SIGTERM, lambda *_: loop.quit())
    signal.signal(signal.SIGINT, lambda *_: loop.quit())

    def await_result():
        if server.done.is_set():
            loop.quit()
            return False
        return True

    GLib.timeout_add(100, await_result)

    try:
        server.register()
        connect_profile(bus, device_path)
        loop.run()
    finally:
        server.unregister()


    if server.levels is None:
        return 1
    emit(mac, server.levels)
    return 0


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "--self-test":
        if len(argv) != 2:
            print("usage: airpods-battery.py --self-test <hex-message>",
                  file=sys.stderr)
            return 2
        return run_self_test(argv[1])
    if len(argv) != 1:
        print("usage: airpods-battery.py <MAC>", file=sys.stderr)
        return 2
    return run_probe(argv[0])


if __name__ == "__main__":
    sys.exit(main())
