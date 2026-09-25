---
title: Moving an existing Mac
description: What happens to Macs installed from earlier Apple Silicon projects, and how the move runs.
section: Using it
---

Macs already running Omarchy from an earlier Apple Silicon project move to this stack in place, without a reinstall. Nothing moves yet: the move is switched on only after the official packages are published and promoted, and after it has been accepted for each kind of install below.

| Installed from | What the move does |
| --- | --- |
| Omarchy MX Mac | Swaps its runtime packages for official Omarchy in one transaction and retires its own updaters, so the Mac never returns to them. Encryption, snapshots and Limine stay as they are. |
| The earlier omarchy-mac project, on GRUB and the Asahi kernel | Converts the checkout-based install to packages, removes the unsigned package repository and sets up official package trust, and moves from the Asahi kernel to Aurora and from GRUB to Limine. An unencrypted Mac stays unencrypted. |
| Test builds of this stack | Replaces the test packages with the official ones, even where a test build carries a higher version. |

## How the move runs

The move arrives as one migration in an ordinary `omarchy update`. It keeps a journal, so a power cut or a lost network part-way through is resumed on the next run rather than started over. In order, it:

1. refuses, before changing anything, a state it does not support;
2. backs up cached packages, configuration, the LUKS header and the boot and EFI system partitions;
3. sets up trust in the official keyring on its own;
4. downloads and verifies the complete signed package set before installing any of it;
5. switches the package repositories and removes old trust settings;
6. runs the package transaction;
7. installs the Aurora kernel, m1n1 and U-Boot where they are missing, and rebuilds the device trees;
8. stages and checks Limine before it replaces the active boot loader;
9. asks for a reboot and checks the Mac came up on the new chain;
10. removes what was only kept for the move.

Your administrator configuration and any services you masked are kept.

Encrypting an unencrypted Mac is not part of the move. It may come later as a separate, opt-in step.
