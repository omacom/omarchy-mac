---
title: Encryption and passwords
description: Disk encryption on a Mac, the first-boot re-key, the recovery passphrase, password changes and resetting a Mac.
section: Using it
---

Encryption on a Mac is chosen in the installer and carried out on the Mac's first boot. The result is the same LUKS root an x86 Omarchy install has, unlocked with your own password. [Security](https://omarchy.org/manual/security/) in the Omarchy manual covers the rest.

## Turning it on

Choose encryption in the installer. The image is written unencrypted, with a temporary install key for the first boot. On that boot, from the initramfs and before the root is mounted, the root file system is converted to LUKS in place: it is shrunk, re-encrypted and its boot entries and initramfs are rebuilt to unlock it. The conversion keeps a recovery journal on the boot partition, so an interrupted conversion can be picked up again.

A Mac that was not asked to encrypt is never touched. The conversion needs a marker the installer writes and refuses to run without it.

## First boot: your password and a recovery passphrase

Owner provisioning then asks for your name and password, as on x86. On an encrypted Mac it also:

- makes your password the disk password and removes the temporary install key, so no key from the image can unlock your disk;
- creates a recovery passphrase and shows it once. Write it down and keep it away from the Mac: it unlocks the disk if you forget your password.

The next boot unlocks the disk with your password. At the prompt the built-in keyboard and trackpad work, because their drivers are loaded early in the initramfs. A Bluetooth keyboard does not, just as on x86: use the built-in keyboard or a wired one.

## Changing passwords

Change passwords under _Update > Password_ in the Omarchy menu, as on x86. On a Mac your disk password and your login password start out the same. Changing the disk password changes the LUKS key first and your login password second, and records each step, so an interruption resumes rather than leaving the two out of step. It applies only to the root volume: changing the password of another encrypted drive never changes your login.

## Resetting the Mac for a new owner

_Setup > Reset Computer_ hands a Mac to its next owner, as described in [Security](https://omarchy.org/manual/security/). It works on Macs installed with the installer app. On a Mac it also re-keys the encryption for the next owner, resets the Limine menu and checks the boot files before it activates the clean system. If a check fails, it rolls back and leaves the current system in place.

A clean system expects the kernel it was installed with. When the kernel on the boot partition has moved on since, the reset refuses rather than activating a root that kernel cannot boot.
