---
title: Boot chain
description: From Apple firmware to the Omarchy root, and what omarchy-mac-boot adds to the initramfs.
section: How it is built
---

An Apple Silicon Mac has no UEFI of its own. Everything up to U-Boot is Apple's firmware and the Asahi Linux project's boot stages. Omarchy's part starts at the boot loader, Limine, the same boot loader x86 Omarchy uses.

{{diagram:boot-chain}}

## Stages

| Stage | Package | What it does |
| --- | --- | --- |
| iBoot | Apple firmware | Enforces the boot policy set in recoveryOS and starts the chosen boot object |
| m1n1 | `m1n1-aurora` | Asahi's m1n1 built for the Aurora kernel, with the Omarchy boot logo. Stage 1 is the boot object iBoot starts; stage 2 initialises the hardware Apple's firmware leaves alone and passes the device tree on. |
| U-Boot | `uboot-asahi` | The UEFI implementation on Apple Silicon, built with a silent console: no banner, no logo, no boot delay. Loads the boot loader from the EFI system partition. |
| Boot loader | Limine | Loaded from the EFI system partition. Lists one entry per kernel and per snapshot. |
| Kernel and initramfs | `linux-aurora`, `omarchy-mac-boot` | A systemd initramfs built by mkinitcpio, carrying the vendor firmware and the Apple input drivers, bundled with the kernel as a unified kernel image |
| Root | Omarchy | A btrfs root on the `@` subvolume, with snapper snapshots and, optionally, LUKS |

## Limine

- U-Boot loads Limine from `EFI/BOOT/BOOTAA64.EFI` on the EFI system partition.
- `limine-mkinitcpio-hook` builds a unified kernel image on every kernel or initramfs change and keeps it on the EFI system partition, where U-Boot can reach it.
- `limine-snapper-sync` lists snapper snapshots in the boot menu, and `omarchy-snapshot restore` restores one. See [Snapshots and recovery]({{page:snapshots}}).
- The menu the user sees is Limine's, the same as on x86 Omarchy.

GRUB stays only as a recovery fallback while older Macs are moved over. New installs never boot through it.

## The kernel

There is one kernel, `linux-aurora`, built in omarchy-pkgs from a pinned commit of [aurora-silicon/linux](https://github.com/aurora-silicon/linux). It provides `linux-asahi`, so nothing above the kernel cares about the name, and it does not provide `linux`, so it never replaces another aarch64 machine's kernel. Kernel tooling finds kernels by their package base, not by what they provide.

## Initramfs

The initramfs is systemd-based. Omarchy sets the platform's baseline of mkinitcpio hooks, and `omarchy-mac-boot` adds Apple fragments on top, in order, rather than overwriting it. The fragments only apply on an Apple Silicon Mac:

- `MODULES` entries for the Apple keyboard and trackpad drivers, added only when the running kernel really has them as modules, so a kernel that builds a driver in does not break a later `mkinitcpio -P`;
- a vendor firmware service that copies Apple firmware onto the root, and a second copy before `cryptsetup-pre.target` on encrypted Macs, so Wi-Fi and input work at the passphrase prompt;
- a Plymouth drop-in, so the passphrase prompt is graphical;
- the `kmod-static-nodes` ordering fix that btrfs roots need on Apple hardware.

## Encryption

The conversion runs in the initramfs before `sysroot.mount`. It shrinks the file system, re-encrypts it in place, then regenerates the boot entries and the initramfs with `sd-encrypt`. The next boot unlocks the volume with the owner's password. The unit requires a pending marker written by the installer and refuses to run without it, so a Mac installed without encryption is never touched. [Encryption and passwords]({{page:security}}) covers what the owner sees.

## Boot verification

After an update that touches the boot path, `omarchy-mac-boot` checks the kernel, the initramfs hooks, the device trees, the m1n1 payload and the Limine entries against what the installed packages say they should be. A mismatch stops the update before it offers a reboot. Hand-editing any of those files makes the next check fail, which is the point.
