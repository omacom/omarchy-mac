---
title: Snapshots and recovery
description: Snapshots in the Limine menu, restoring one, and what a snapshot does not cover on a Mac.
section: Using it
---

Snapshots work as they do on x86 Omarchy, described in [System snapshots](https://omarchy.org/manual/system-snapshots/): `omarchy update` takes one before every package sync, `omarchy-snapshot create` takes one by hand, and the Limine boot menu lists them.

## Booting and restoring a snapshot

1. Restart and pick the snapshot in the Limine menu by its date and Omarchy version.
2. Once it is up, click the notification to restore it, or run `omarchy-snapshot restore`.

Restore from the snapshot you booted: run from the current system, the restore tells you to boot the snapshot first. If you pick a different snapshot from the restore's own list instead, it's checked after the restore. When it doesn't match, you're told not to reboot and how to put the previous root back. A snapshot holds the root file system, not `/home`, so it undoes a broken update but does not bring back lost files.

Snapshots taken before Limine was activated on your Mac are not in the Limine menu. Limine saved no kernel for them, so they can't be booted or restored. `limine-snapper-list` shows the snapshots the menu offers.

## What a snapshot does not hold on a Mac

Part of what boots a Mac lives outside the root file system: the kernel and initramfs on the boot partition, Limine on the EFI system partition, and m1n1, U-Boot and the device trees. A snapshot does not roll those back.

So before a restore, the snapshot is checked against the current boot files, and the restore is refused when they don't match it, for example when the snapshot was taken before a kernel, m1n1, U-Boot or Limine update. The message says what differs and lists the snapshot's kernel, boot firmware and Limine packages. To restore that snapshot anyway, boot the current system, install those package versions with `pacman`, then boot the snapshot again and restore it.

The check runs from the snapshot you booted. A snapshot taken before your Mac had it restores unchecked, so compare its packages with the current ones first.

A Mac that still boots GRUB, from before the move to Limine, has no snapshot menu. There `omarchy-snapshot restore` runs from the current system, lets you pick a snapshot, and refuses one that doesn't carry the kernel on the boot partition.

## The boot menu stays

Limine always sits in front of Omarchy on a Mac. _Setup > Direct Boot_ refuses to run on Apple firmware, so the snapshot menu is always one restart away.

To reach macOS instead, hold the power button at startup. In macOS, System Settings → General → Startup Disk sets the default.
