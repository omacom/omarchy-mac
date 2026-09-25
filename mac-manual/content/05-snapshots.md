---
title: Snapshots and recovery
description: Snapshots in the Limine menu, restoring one, and what a snapshot does not cover on a Mac.
section: Using it
---

Snapshots work as they do on x86 Omarchy, described in [System snapshots](https://omarchy.org/manual/system-snapshots/): `omarchy update` takes one before every package sync, `omarchy-snapshot create` takes one by hand, and the Limine boot menu lists them.

## Booting and restoring a snapshot

1. Restart and pick the snapshot in the Limine menu by its date and Omarchy version.
2. Once it is up, click the notification to restore it, or run `omarchy-snapshot restore`.

A snapshot holds the root file system, not `/home`, so it undoes a broken update but does not bring back lost files.

## What a snapshot does not hold on a Mac

Part of what boots a Mac lives outside the root file system: the kernel and initramfs on the boot partition, Limine on the EFI system partition, and m1n1, U-Boot and the device trees. A snapshot does not roll those back.

So before a restore, the snapshot is compared with the current boot files, and you are told when it predates them, for example when it was taken before a kernel update. That keeps you from restoring a root the installed kernel cannot boot.

## The boot menu stays

Limine always sits in front of Omarchy on a Mac. _Setup > Direct Boot_ refuses to run on Apple firmware, so the snapshot menu is always one restart away.

To reach macOS instead, hold the power button at startup. In macOS, System Settings → General → Startup Disk sets the default.
