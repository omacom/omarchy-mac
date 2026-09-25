---
title: What is on the disk
description: The packages on an installed Mac, how Mac-only code stays on Macs, and how to override a Mac default.
section: How it is built
---

An installed Mac is an upstream Omarchy installation plus two Mac packages and the Apple boot chain. The file layout is upstream's, described in the Omarchy repository's [file-layout.md](https://github.com/omacom/omarchy/blob/quattro/docs/file-layout.md).

## Packages

| Package | Contents |
| --- | --- |
| `omarchy-settings` | `/etc/skel`, `/etc` drop-ins, boot loader and snapper configuration, Plymouth and SDDM themes, branding. One aarch64 build that picks the Apple profile at runtime. |
| `omarchy` | The `omarchy-*` commands, install scripts, migrations, themes and the Quickshell desktop |
| `omarchy-mac` | Microphone mapping, Wi-Fi resume recovery, the iwd Wi-Fi backend for NetworkManager, the notch setting |
| `omarchy-mac-boot` | Initramfs fragments, vendor firmware hooks, first-boot and encryption units, Limine and U-Boot deployment, boot verification |
| `linux-aurora` | The kernel, its headers and the device trees |
| `m1n1-aurora`, `uboot-asahi` | The boot stages between Apple's firmware and Limine |
| `limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync` | The boot loader, unified kernel images and snapshot entries |
| `omarchy-keyring` | The pacman keys for `[omarchy]`, upstream's package unchanged |

Package lists are composed from a base, an architecture and a platform. Only the Apple profile adds the Asahi repositories and the Apple packages.

## Mac code stays on Macs

One detector, `omarchy-hw-platform`, answers `apple-silicon`, `qualcomm`, `generic-aarch64` or `generic`. It reads the device-tree identity, falls back to what the kernel reports, and fails rather than guess when the evidence contradicts itself. Every Mac-only step asks it, and Mac services check again when they start, so nothing Apple-specific runs on x86 or on another ARM machine such as a Snapdragon laptop.

A pacman hook in `omarchy-settings` refuses a transaction that would install a package tagged for another platform. Image builds declare their target platform in a manifest rather than reading the build machine, and live system changes ignore environment overrides.

## Overriding a Mac default

`omarchy-mac` installs its defaults where each tool keeps vendor configuration: `/usr/lib/NetworkManager/conf.d`, `/usr/lib/systemd`, `/usr/lib/modprobe.d` and `/usr/share/wireplumber/wireplumber.conf.d`. A file of the same name under `/etc`, or in your own configuration, takes precedence, and updates never rewrite it. Services you mask stay masked.

## Things not to do

- Do not replace a package from `[omarchy]` with an AUR build of the same software. It moves the Mac outside the qualified set and can block later updates.
- Do not reboot during or after a failed package transaction or a failed boot verification. Keep the output and `/var/log/pacman.log`, and [report it]({{page:hardware}}#reporting-a-problem).
- Do not hand-edit the Limine configuration or the files on the EFI system partition. The next boot verification will refuse the update.
- Do not install another kernel alongside `linux-aurora`. It is the only kernel the boot chain is qualified with.
