---
title: Hardware support
description: Which Macs are supported, what works, the known limitations and how to report a problem.
section: Reference
---

Hardware support is the Asahi Linux project's work, plus what the Aurora kernel adds. Every release is qualified on real Macs before it reaches `rc` or `stable`, and nothing below claims more than has been exercised.

## Supported Macs

A Mac is admitted by its device-tree identifier, never by its marketing name, because one marketing name can cover boards with different hardware. The identifier is what the installer catalog lists and what releases are qualified against. Read yours with:

```bash
cat /proc/device-tree/model
tr '\0' '\n' < /proc/device-tree/compatible
```

In macOS, `sysctl hw.model` shows the model identifier, such as `MacBookPro18,3`.

The first release is qualified on the MacBook Pro 14" M1 Pro (`apple,j314s`) and the MacBook Pro 16" M2 Max (`apple,j416c`). The signed catalog on each channel lists every identifier it admits, and the installer refuses any other Mac before touching the disk. M1 and M2 Macs only: M3 and M4 Macs are not supported.

## Reference machines

| Machine | Role |
| --- | --- |
| MacBook Pro 14" 2021, M1 Pro, `apple,j314s` | Full regression on every release; VM acceptance host |
| MacBook Pro 16" 2023, M2 Max, `apple,j416c` | Multi-display work: five displays through HDMI and USB4. End-to-end installs for installer changes; VM acceptance host |

Boot-critical changes need a cold boot on a test Mac, never only a warm reboot, before a release proceeds. The checklist covers platform identity, desktop and graphics, networking, audio, power and suspend, updates and snapshots.

## What works

This is what the first release is qualified against on both reference Macs. <span class="status ok">works</span> is expected to work on every admitted Mac; <span class="status wip">in progress</span> and <span class="status wip">known issue</span> are tracked.

| Area | Status | Notes |
| --- | --- | --- |
| Apple GPU | <span class="status ok">works</span> | Mesa `vulkan-asahi`, hardware acceleration. A desktop on `llvmpipe` means something is wrong. |
| Internal display, brightness | <span class="status ok">works</span> | The panel includes the strip beside the notch |
| Keyboard, backlight, trackpad | <span class="status ok">works</span> | Drivers loaded early, so they work at the passphrase prompt. The backlight follows the ambient light sensor. See [Keyboard and trackpad]({{page:keyboard}}). |
| Wi-Fi, Bluetooth | <span class="status ok">works</span> | NetworkManager with the iwd backend. Wi-Fi on BCM4378 and BCM4387 chips recovers after resume. Wi-Fi 6E Macs join on 2.4 and 5 GHz: a 6 GHz join passes no traffic with the current firmware. |
| Speakers, microphone, headphones | <span class="status ok">works</span> | Asahi's DSP chain with `speakersafetyd` protecting the speakers. The microphone array is mapped, and a headset microphone takes priority when plugged in. |
| Suspend and resume | <span class="status ok">works</span> | |
| Battery, lid, power profiles | <span class="status ok">works</span> | |
| External displays | <span class="status ok">works</span> | HDMI on models that have it, USB4 and DisplayPort alt-mode through the Aurora kernel. Five displays on the M2 Max. A third and fourth display rely on an aquamarine fix carried until Hyprland releases it. |
| Variable refresh rate, camera (ISP), always-on processor | <span class="status ok">works</span> | Aurora kernel |
| Hardware video decode | <span class="status wip">in progress</span> | VA-API decoding of H.264, HEVC Main and Main10, and VP9 8 and 10-bit, tested on a 13" M1 MacBook Pro. Other models, the release kernel and browser acceleration are still open. No hardware encoding. |
| Screen recording | <span class="status ok">works</span> | Encoded on the CPU through `wf-recorder`, because the Apple GPU has no supported hardware video encoder |
| Widevine DRM in browsers | <span class="status ok">works</span> | When the package is available from the Asahi repositories |
| Steam | <span class="status ok">works</span> | Optional, through FEX (`omarchy-steam-fex`) |
| Fullscreen window on a very wide display | <span class="status wip">known issue</span> | Hyprland paints only a band of a fullscreen window on a 5120×1440 output next to a scaled internal display. Upstream Hyprland issue. |
| Fourth external display after HDMI unplug | <span class="status wip">known issue</span> | A stale DisplayPort link on the M2 Max after unplugging HDMI; replug or reboot |
| Text console between Plymouth and the greeter | <span class="status wip">known issue</span> | Cosmetic, a few seconds |

## What Asahi supports on your chip

Everything below the desktop is the Asahi Linux project's work, and the authoritative, current list of what each Apple chip supports is theirs:

- [M1 feature support](https://asahilinux.org/docs/platform/feature-support/m1/)
- [M2 feature support](https://asahilinux.org/docs/platform/feature-support/m2/)
- [Overview across chips](https://asahilinux.org/docs/platform/feature-support/overview/)

Anything marked work in progress there, Thunderbolt device support among them, is work in progress here too. The Aurora kernel adds the display, camera and USB4 work described above.

## Reporting a problem

Open an issue on [omacom/omarchy-mac](https://github.com/omacom/omarchy-mac/issues), or on [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer/issues) for the macOS installer app. Include the output of:

```bash
uname -a
cat /proc/device-tree/model
tr '\0' '\n' </proc/device-tree/compatible
omarchy-hw-platform
pacman -Q omarchy omarchy-settings omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi
pacman-conf --repo-list
```

For an update that stopped, add the update output and `/var/log/pacman.log`. For an installer that stopped, add the app's log folder under `~/Library/Logs/`.

Never post passwords, your recovery passphrase, Wi-Fi credentials, private keys or complete connection profiles.
