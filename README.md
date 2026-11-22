# Omarchy Mac

> [!IMPORTANT]
> **The Omarchy Mac and Omarchy MX Mac teams joined Omacom, and together we built
> the streamlined Apple Silicon version of Omarchy, first released with Omarchy 4.5.
> Omarchy for Apple Silicon is now an official Omacom solution.**

This repository is no longer maintained. Thank you to everyone who installed,
tested, reported and contributed.

## Install Omarchy for Apple Silicon

From macOS:

```bash
brew install omacom/mac/omarchy
```

Or download the [Omarchy installer](https://github.com/omacom/omarchy-mac-installer/releases).
Read the [Mac support page](https://github.com/omacom/omarchy/blob/quattro/manual/44-mac-support.md).

## Already on Omarchy Mac?

Your install keeps running, and its system packages still update, but it gets no more
Omarchy updates. There is no in-place upgrade. To move:

1. **Back up** your home folder and anything else you want to keep, off the Mac.
2. **Remove** the old install from macOS with the Omarchy installer, so its disk space is free.
3. **Install** Omarchy for Apple Silicon, as above.
4. **Restore** your files.

The [Coming from Omarchy Mac](https://github.com/omacom/omarchy/blob/quattro/manual/44-mac-support.md#coming-from-omarchy-mac)
section has each step in detail.

## Where things are now

| What | Where |
|---|---|
| Installer | [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer) |
| Mac packages, Mac bugs, manual source | [omacom/omarchy-mac-pkgs](https://github.com/omacom/omarchy-mac-pkgs) |
| Kernel | [omacom/linux-aurora](https://github.com/omacom/linux-aurora) |
| Boot | [omacom/m1n1](https://github.com/omacom/m1n1) |
| GPU | [omacom/mesa](https://github.com/omacom/mesa) |
| Omarchy itself | [omacom/omarchy](https://github.com/omacom/omarchy) |
| Help | [Omarchy Discord](https://omarchy.org/discord) |

The old code is still here, on the [`quattro`](https://github.com/omacom/omarchy-mac/tree/quattro)
and [`main`](https://github.com/omacom/omarchy-mac/tree/main) branches.
