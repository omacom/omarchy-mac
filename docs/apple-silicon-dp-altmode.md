# Apple Silicon: external DisplayPort over USB-C

Plugging a monitor into an Apple Silicon Mac **over USB-C** and getting nothing
is expected on a stock Asahi kernel, not a fault. This documents why, so the
question can be answered in one line instead of an afternoon of cable swapping.

**This is about DisplayPort over USB-C only.** Machines with a dedicated HDMI
port — the 14" and 16" MacBook Pros and the Mac mini — drive it through a
separate path that is not covered here, and it appears as its own DRM connector
(`HDMI-A-1`). If you have an HDMI port, try it: nothing below applies to it.

## Symptoms

- An external monitor over USB-C stays dark. No connector appears, or one
  appears and never leaves `disconnected`.
- The cable and the monitor are fine and work on other machines.
- `lsusb` shows a "USB Billboard Device" for the monitor, which reads like a
  failure but is not — see below.
- SuperSpeed disappears while the monitor is attached, which also reads like a
  bad cable and also is not.

## Why nothing happens

Apple Silicon drives external displays from a display controller separate from
the one running the internal panel. A stock Asahi device tree does not wire any
USB-C connector to that controller, and on some SoCs leaves it disabled as well.
With no connector pointing at an enabled external controller, there is nothing
for an external display to attach to, and the plug event goes nowhere.

The exact shape differs by SoC, but the outcome is the same:

- **M1 (t8103)** — the external controller is `dcp@271c00000`, compatible
  `apple,t8103-dcpext`. The stock `t8103-j293.dtb` ships it `status = "disabled"`
  and no connector carries a `displayport` property. Verified by comparing the
  stock and patched DTBs for this machine.
- **M2 (t8112)** — the external controller is `apple,t8112-dcpext` and there is
  an `apple,t8112-dptx-phy` beside it. Both are disabled on the laptops
  (`j413`, `j415`, `j493`) and both are *enabled* on the Mac mini (`j473`) — yet
  no `t8112` device tree carries a `displayport` property on any USB-C
  connector. Verified on an `apple,j413` and against the shipped DTBs.
- **M2 Pro/Max (t6021)** — three display controllers, of which two are
  `apple,t6020-dcpext` and one of those is *enabled*; no connector carries
  `displayport`. Verified on an `apple,j414c`. External display still does not
  come up there, so on t6021 a disabled controller is not the whole story — the
  missing connector wiring is what both shapes have in common.

The `j473` case is the clearest evidence that both halves have to be tested. It
is a stock machine with the external controller and its PHY enabled, and USB-C
DisplayPort still does nothing there, because nothing wires a connector to that
controller. A check that accepted an enabled controller on its own would report
that machine as working. The enabled controller appears to serve HDMI rather
than USB-C — the machines that have it enabled are the ones with an HDMI port —
though t8103 does not fit that pattern cleanly: the M1 mini (`j274`) has HDMI
and ships `dcpext` disabled, and no t8103 device tree carries the `dptx-phy`
binding at all.

Note that the external controller is not named `dcpext` on either machine. Every
display controller is called `dcp@`; "dcpext-ness" lives in the compatible
string, so a glob for `dcpext@` matches nothing on any Apple Silicon Mac.

That is why the check follows each USB-PD connector's `displayport` phandle to
whichever controller it names, confirms that node is an external one by its
compatible string, and tests its status. It gives the right answer on both
shapes.

On a stock tree the check reports the route as not enabled, which is the correct
answer and the state nearly every machine is in. It reports it as enabled only
once a device tree actually wires a connector to an enabled external controller,
which today means one of the patched trees described below. The M1 this was
written against runs such a tree, which is why the check can be seen returning
both answers; on a stock kernel it returns only the first.

What makes this expensive to diagnose is that every layer fails **silently**.
There is no error in `dmesg`, nothing in the compositor log, and each failure
looks exactly like the one before it from userspace. Everything below the
missing controller works and is already merged: the Type-C PHY does DP mode, the
display crossbar is wired, and the cd321x driver registers the port altmodes,
switches the mux and reads DisplayPort status.

## Things that look like faults and are not

**A "DisplayPort adapter" that is really DisplayLink.** Many cheap adapters and
docks sold as DisplayPort do not use alt mode at all — they are DisplayLink USB
graphics devices. The hub, Ethernet and audio functions enumerate normally and
video never becomes a DRM connector, which is indistinguishable from the gap
described here until you read `idVendor`: DisplayLink is `17e9`. Without the
`evdi` driver such a device cannot produce a display on Linux at all, and no
amount of device tree work will change that. Check the adapter before chasing
the controller.

**The USB Billboard Device.** A monitor that exposes a USB hub will enumerate a
Billboard device. Its presence says nothing about whether alt mode succeeded.

**SuperSpeed disappearing.** With DisplayPort pin assignment C, all four
high-speed lanes carry DisplayPort and USB drops to 2.0. Losing SuperSpeed while
a monitor is attached is what success looks like, not a bad cable.

**Kernel messages from the layers that do work.** The parts below the missing
route load and report normally, and their messages read like faults when you are
already looking for one: `mux_apple_display_crossbar` logging `Switched dpphy to
disconnected state`, or `phy-apple-atc … Failed to lock pipehandler` when a dock
is attached. Neither is the reason nothing appears.

## The port matters, and its number does not

Where DisplayPort is wired is fixed per machine and is usually a single port.
Asahi's own work names them for M1: the front-left USB-C on the 13" MacBook Pro
and Air, the port next to HDMI on the Mac mini, the back-left on the 2-port
iMac, and the back-right-middle on the 4-port iMac.

The `portN` index under `/sys/class/typec` is assigned in i2c probe order and
**is not stable across boots**: the same physical port was observed as `port1`
on one boot and `port0` on the next. Anything that resolves a port must do it by
i2c address, never by the number.

## Checking a machine

```bash
omarchy debug dp-altmode
```

walks the chain in order and stops at the first thing that is not in place:
whether a DisplayPort-capable controller is enabled, which port carries
DisplayPort, where the cable actually is, and what DRM ended up with.

```bash
omarchy-hw-dp-altmode
```

returns true when external DisplayPort output is actually wired up — both that a
USB-C connector carries the `displayport` phandle and that the node it names is
enabled. Either half alone is a half-configured machine, which is why the check
requires both.

## Where the real work is happening

Asahi implements DisplayPort alt mode on the **`fairydust`** branch of their
downstream tree — the device tree changes for t8103, t8112 and t60xx, plus the
`tipd` change that forwards the hotplug event to DRM. That is the canonical
work, it covers M1, M2 and M1/M2 Pro/Max, and it is what converges upstream.

Take it on its own terms: the commits are titled "dp-altmode dts **hacks**" and
"**HACK**: Use drm oob hotplug event" by their own authors, it blesses one
specific port per machine rather than enabling them all, and it carries the
usual downstream caveats — experimental, provided as-is, with cold- and hot-plug
quirks. It is not a supported configuration until Asahi says it is.

Enabling any of this is out of scope for Omarchy at present. It needs a patched
device tree plus out-of-tree kernel modules, and a kernel update silently
reverts all of it, so it is not something to turn on by default in a
distribution that updates kernels unattended.

For an M1-specific writeup — the full chain, the evidence, and one unresolved
bug — see https://github.com/haripako/dp-altmode. It backports the `fairydust`
`tipd` change unmodified and is an additional reference, not a substitute for
the branch above.
