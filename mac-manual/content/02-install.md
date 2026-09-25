---
title: Install on a Mac
description: Verify the installer, pick a channel and a disk split, and install Omarchy next to macOS.
section: Using it
---

Installation starts in macOS. The installer app downloads the signed Omarchy image for the channel you pick, resizes the APFS container, writes the image and hands over to a first boot that finishes the setup on the Mac itself.

<div class="note warn" markdown="1">
There is no public installer release yet. It will be published from [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer/releases) once the first image is qualified. Until then the installer is for testers.
</div>

## Before you begin

- Back up macOS and anything you care about. The installer shrinks your macOS volume.
- Check your model on the [Hardware support]({{page:hardware}}) page. The installer refuses any Mac its signed catalog does not list, before it touches the disk, and names the Macs it does support.
- The release carries the macOS system firmware the Omarchy volume boots with, in the versions it knows about. A Mac running a newer macOS than the release knows about cannot install until the release is updated.
- Keep at least 50 GB free on the internal SSD. 100 GB is comfortable.
- Plug in power and use a reliable Internet connection. The image is a multi-gigabyte download.
- Expect model-specific limits around external displays, speakers, cameras and power management.

## Verify the installer

The installer ships as a signed and notarized `.pkg`. Verify it before opening it, using the file name you downloaded. Both commands must accept it and report an Apple Developer ID, and the identity must be the one named on the release page:

```bash
pkgutil --check-signature ~/Downloads/<installer>.pkg
spctl -a -vv -t install ~/Downloads/<installer>.pkg
```

If you unpack the app yourself, check it the same way. Gatekeeper must report `Notarized Developer ID`:

```bash
codesign --verify --deep --strict ~/Downloads/<installer>.app
spctl -a -vv -t execute ~/Downloads/<installer>.app
```

## Run the installer

1. Open the `.pkg`. It installs the installer app into `/Applications`, together with a privileged helper that performs the disk work.
2. Open the app. It fetches the signed catalog for the selected channel and checks the catalog signature, the sequence number and the SHA-256 of every file it downloads.
3. The app opens on **Stable** at every launch and always shows the channel it is installing. Choose **RC** in the **Release Channel** menu only if the Mac should take release candidates first; the choice lasts until the app quits. See [Updates and channels]({{page:updates}}).
4. Choose how much space to give Omarchy. The APFS container is shrunk, and four partitions are created: a small APFS stub for the boot object, an EFI system partition, a boot partition and a root partition that fills the space you chose.
   While this screen is up the app downloads the image in the background, over Wi-Fi or Ethernet only, and changing the split does not restart the download. **Install** stays disabled until the download matches the signed catalog. If the download fails, the strip under the disk split names the check that failed, for example not enough free space or a file that does not match the signed release, and offers **Try again**.
5. Choose whether to encrypt the root file system. Encryption is set up on the first Linux boot and asks for your password on every boot afterwards. See [Encryption and passwords]({{page:security}}).
6. Follow the prompt to complete the boot policy step in recoveryOS. This is Apple's own step and needs your macOS password. The disk is already written when that prompt appears.

The Mac reboots into Omarchy. The [first boot]({{page:install-flow}}) installs Apple's vendor firmware, converts the root to LUKS if you asked for it, creates your account and lands on the desktop.

## When the installer stops

When the Asahi engine stops with an error, the app explains it in plain language: the reason, and whether any disk step had started. The helper keeps the end of the engine's error output, with the machine-owner password and anything shaped like a credential removed, readable only by root, and the app writes its summary to its folder under `~/Library/Logs/`. Attach those when you [report a problem]({{page:hardware}}#reporting-a-problem).

The engine re-checks the approved size against the live disk before it changes anything. When macOS can no longer give up the space you approved, the app says no disk changes were made and offers **Check available space**, which runs the size check again and asks you to approve a fresh split.

A Mac the release does not support is named by model, model identifier and device identifier, and the message lists the Mac families the channel's signed catalog admits.

## Switch between macOS and Omarchy

Hold the power button at startup to pick macOS or Omarchy. In macOS, System Settings → General → Startup Disk sets the default.
