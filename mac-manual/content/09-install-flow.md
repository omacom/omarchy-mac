---
title: How an install works
description: What the installer app, the Asahi engine, the image and the first boot each do.
section: How it is built
---

An install is three programs handing over to each other: the macOS app decides what to install and proves it is genuine, the Asahi installer engine does the disk work Apple requires, and `omarchy-mac-boot` finishes the job on the first Linux boot.

{{diagram:install-flow}}

## The app

The app ships as a signed and notarized `.pkg` that installs the app bundle and a privileged helper. The helper is the only part that runs as root, and the app talks to it over a Mach service whose code-signing requirement is pinned to the same Developer ID.

The bundle carries the channel list, the default channel and the SHA-256 of the Ed25519 trust root every catalog must be signed with. Because the trust root is in the app, rotating the signing key means shipping a new app.

On launch the app:

1. downloads the channel's signed catalog and verifies the signature against the bundled trust root;
2. refuses a catalog whose sequence number is lower than the last one it accepted, or that reuses that number for different contents;
3. checks its own version against the catalog's minimum installer version, so an old app stops before downloading a release it cannot install;
4. checks the Mac's device-tree identity against the models the catalog admits;
5. downloads the image parts and the engine overlay the catalog names, verifying each SHA-256, and reuses a cached file only when its size and hash match.

## The engine

The engine is the upstream [Asahi Linux installer](https://github.com/AsahiLinux/asahi-installer), pinned by digest in the catalog, with Omarchy's patches and a Python overlay on top. Omarchy does not reimplement Apple's boot process: APFS resizing, partition creation, m1n1, the boot policy and recoveryOS remain the Asahi project's work.

The layout is the engine's four partitions: an APFS stub holding the stub macOS that owns the boot object, a 500 MiB EFI system partition, a 2 GiB boot partition and a root partition that fills the space the user chose. The engine prepares the target, writes the boot and root images with m1n1 and the device trees, and only then asks the user to finish the boot policy step in recoveryOS.

The engine bundled in the app only inspects the Mac. The engine that performs the install always comes from the catalog, so an engine fix can ship without a new app.

## The image

The Mac image is built by the image builder in omarchy-mac-installer from signed packages pinned to one omarchy-mac commit: kernel, initramfs, m1n1, U-Boot, Limine, official Omarchy, the two Mac packages and the whole default package set. It is a complete Omarchy installation with no user yet. The build declares its target platform in a manifest instead of reading the build machine's hardware, and the finished image is inspected, from the initramfs and device trees to m1n1, U-Boot and Limine, before it can reach a catalog.

Before a release, the image is installed and booted in KVM on a test Mac, once plain and once encrypted, and then cold booted on the M1 Pro and the M2 Max. The Aurora kernel cannot boot on QEMU's virtual machine, so the VM harness boots a generic Arch Linux ARM kernel with an initramfs built from the image's own hooks. VM success never stands in for the hardware run.

## First boot

`omarchy-mac-boot` owns everything Apple-specific about booting. On the first boot it:

- copies the Apple vendor firmware the Asahi engine extracted from macOS into the running system and the initramfs;
- loads the Apple keyboard and trackpad drivers early, so the passphrase prompt and the greeter both have input;
- converts the root file system to LUKS if the installer asked for it, from the initramfs and before the root is mounted;
- hands over to owner provisioning: your account and password, the disk re-key and the recovery passphrase;
- leaves the remaining model-specific hardware steps for your first desktop session, which runs them without asking.

Every one of those files is owned by a package, so a fix to the boot path reaches installed Macs through `omarchy update`.
