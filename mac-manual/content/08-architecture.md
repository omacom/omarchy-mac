---
title: How it fits together
description: The repositories, the package repository and the installer, and how each pins the one before it.
section: How it is built
---

Omarchy on a Mac is official Omarchy plus a small set of Mac packages, all published from Omarchy's own package repository, and a macOS installer app that writes an image built from those same packages.

{{diagram:repositories}}

## Repositories

| Repository | What it holds |
| --- | --- |
| [omacom/omarchy](https://github.com/omacom/omarchy) | The desktop, the same as on every other Omarchy machine. Mac decisions go through one platform detector and a few dispatch points that do nothing on other platforms. |
| [omacom/omarchy-mac](https://github.com/omacom/omarchy-mac) | The sources of `omarchy-mac` and `omarchy-mac-boot`, the Mac tooling (release orchestration, VM and hardware acceptance, evidence manifests) and this manual |
| [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs) | The recipes that build every package, the Mac ones included, and the signed `[omarchy]` repository with its `edge`, `rc` and `stable` channels |
| [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer) | The macOS installer app, its pinned Asahi installer engine and the Mac image builder |

Until the generic Mac changes are merged into omacom/omarchy, the `quattro-upstream` branch of omarchy-mac carries them. It is the one integration branch for Apple Silicon work.

## Two Mac packages

| Package | What it owns | Why it is separate |
| --- | --- | --- |
| `omarchy-mac` | Runtime hardware support: microphone mapping, Wi-Fi resume recovery, the Wi-Fi backend, the notch | Runtime fixes can ship without waiting for a boot qualification |
| `omarchy-mac-boot` | Initramfs fragments and vendor firmware, encryption and first boot, Limine and U-Boot deployment, post-update boot verification, factory reset | Every change needs a cold boot on real Macs before it is released |

Each has its own version and tests, and they talk through versioned interfaces rather than reaching into each other.

## Cross-repository pins

Each step pins the one before it by content, never by branch:

1. A Mac recipe in omarchy-pkgs names the exact omarchy-mac commit it builds from.
2. A package reaches `rc` and `stable` only through an explicit promotion after qualification.
3. The Mac image is built from signed packages pinned to one omarchy-mac commit, the whole boot set included, and is inspected before it can reach a catalog.
4. The installer catalog names the image by URL and SHA-256, and the app checks the catalog's signature and sequence before it downloads anything.

A change anywhere therefore produces a new artefact all the way down, and an old artefact can be reproduced from its pins.

## Distribution

Packages are served from `pkgs.omarchy.org` like any other Omarchy package. The installer reads a signed catalog per channel from a download host, and released images and installer builds are never rewritten: only the channel pointers move, and each move is a signed catalog with a larger sequence number than the last.

For now the installer keeps the signing identity and catalog hosting it was extracted with. Moving them to Omarchy's own is a change to the installer's build configuration, not to anything on your Mac.
