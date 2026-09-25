---
title: Omarchy on Apple Silicon
description: Omarchy on M1 and M2 Macs, installed from macOS and living next to it.
section: Using it
---

Omarchy runs on Apple Silicon Macs next to macOS. It is the same [Omarchy](https://omarchy.org) as on any other computer, with the same desktop, keybindings and updates, plus what Apple hardware needs: a macOS installer app instead of an ISO, Arch Linux ARM and the Asahi Linux stack instead of x86 Arch, the Aurora kernel, and a boot chain that lives next to macOS.

Everything that is not Mac-specific is upstream Omarchy, so the [Omarchy manual](https://omarchy.org/manual/) applies unchanged. This manual covers only what is different on a Mac.

<div class="note warn" markdown="1">
This stack is still being qualified and has no public release yet. Mac packages land on Omarchy's `edge` channel first and reach `rc` and `stable` only after cold-boot qualification on a MacBook Pro 14" M1 Pro and a 16" M2 Max. Read these pages as what the first release installs. [Status]({{page:status}}) says what is left.
</div>

## What a Mac runs

| Part | What it is |
| --- | --- |
| Desktop | Official Omarchy: the same `omarchy` and `omarchy-settings` packages every Omarchy machine runs |
| Mac support | Two packages: `omarchy-mac` for runtime hardware support, and `omarchy-mac-boot` for the initramfs, encryption, first boot and the boot loader |
| Kernel | `linux-aurora`, built from [aurora-silicon/linux](https://github.com/aurora-silicon/linux), with `m1n1-aurora` and `uboot-asahi` |
| Boot | m1n1, then U-Boot, then Limine, with your snapshots in the boot menu |
| Packages | Signed packages only: Omarchy's own `[omarchy]` repository for aarch64, Arch Linux ARM and the Asahi repositories |
| Installer | The macOS app from [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer) |

## Who this is for

- Owners of an M1 or M2 Mac who want Omarchy as a daily driver next to macOS.
- People already running Omarchy on a Mac from an earlier Apple Silicon project, who want to know what changes: see [Moving an existing Mac]({{page:migrate}}).
- Contributors who need the map of packages, repositories and release gates.

## Where to start

1. [Hardware support]({{page:hardware}}): check your Mac first.
2. [Install on a Mac]({{page:install}}): verify and run the installer.
3. [Updates and channels]({{page:updates}}): how updates arrive and what keeps a Mac bootable.

<div class="note" markdown="1">
Omarchy on Apple Silicon depends on the Asahi Linux project and the Aurora kernel. It is not affiliated with Apple or the Asahi Linux project, and it is not intended for Parallels, virtual machines or non-Apple ARM systems.
</div>
