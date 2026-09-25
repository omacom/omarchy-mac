---
title: Updates and channels
description: Which channel a Mac follows, what omarchy update does on a Mac, and what is signed by what.
section: Using it
---

A Mac updates like any other Omarchy machine: `omarchy update`, the same channels, a snapshot before each update. The Mac packages come from the same repository, and the updater adds one guarantee Apple hardware needs: the boot files stay coherent, or the update refuses to finish.

## Channels

An installed Mac follows Omarchy's own channels, described in [Updates](https://omarchy.org/manual/updates/) in the Omarchy manual. The installer offers two of them:

| Channel | Who it is for |
| --- | --- |
| `stable` | Daily drivers. The installer opens on it. |
| `rc` | Macs that should take release candidates first |

`edge` is where Mac packages land first. It is for testers and lab Macs, and the installer does not offer it. Move an installed Mac between channels with the ordinary command:

```bash
omarchy-channel-set rc
```

The Mac packages (`omarchy-mac`, `omarchy-mac-boot`, `linux-aurora`, `m1n1-aurora`, `uboot-asahi`) reach `rc` and `stable` only after a cold boot on real Macs, by a deliberate promotion. They are built for aarch64 only and nothing generic depends on them, so a non-Apple ARM machine that shares the repository never installs them.

## The kernel

Every Mac runs `linux-aurora`, built from [aurora-silicon/linux](https://github.com/aurora-silicon/linux). On top of the Asahi Linux kernel it adds DisplayPort alt-mode and USB4 external monitors, variable refresh rate, the camera signal processor and the always-on processor.

It stands in for `linux-asahi`, and `linux-aurora-headers` for `linux-asahi-headers`, so anything that asks for the Asahi kernel or its headers is satisfied. It does not claim the generic `linux` name, so it can never be picked as another ARM machine's kernel.

## How an update runs on a Mac

`omarchy update` does what it does everywhere:

1. It takes a snapper snapshot before the package sync. `snapper list` shows it.
2. It updates packages from `[omarchy]` on your channel and from the live Arch Linux ARM and Asahi mirrors, as upstream.
3. It runs pending migrations.

When a kernel or boot package changes, `omarchy-mac-boot` rebuilds the initramfs and the Limine boot entries and keeps the device trees, m1n1 and U-Boot in step with the kernel. Then it checks the result: the kernel, the initramfs, the device trees, the m1n1 payload and the Limine entries must match what the installed packages say they should be.

If that check fails, the update refuses to finish, says what failed and does not offer a reboot. Do not reboot. Keep the output and [report it]({{page:hardware}}#reporting-a-problem).

## What is signed, and by what

Nothing is trusted because of where it came from. Each artefact carries its own signature or digest, and each is checked on your Mac by something that was not downloaded alongside it.

{{diagram:trust-chain}}

| Artefact | Key |
| --- | --- |
| Packages in `[omarchy]`, the Mac packages included | Omarchy's package signing key, trusted through `omarchy-keyring` |
| Channel catalogs the installer reads | One Ed25519 key held in a maintainer's Keychain. Its public half is compiled into the app, so rotating it means shipping a new app. |
| The image | The SHA-256 of every part, listed in the signed catalog |
| Installer app and `.pkg` | An Apple Developer ID, notarized |

pacman runs with `SigLevel = Required`, so an unsigned package is refused. No repository on a Mac is configured with `TrustAll`.
