---
title: Status
description: Where the Apple Silicon stack stands, and what is deliberately left out of the first release.
section: Reference
---

This manual describes the stack the first release installs. It is being built on the `quattro-upstream` branch of omarchy-mac, following [the convergence spec](https://github.com/omacom/omarchy-mac/blob/quattro-upstream/docs/apple-silicon-convergence.md). Until that release, read every page as the target, not as something you can install today.

## Order of work

1. The installer app on omacom/omarchy-mac-installer reaches parity with the last qualified Apple Silicon installer.
2. The Mac packages (`omarchy-mac`, `omarchy-mac-boot`, `linux-aurora`, `m1n1-aurora`, `uboot-asahi` and the carried aquamarine) land on Omarchy's `edge` channel, aarch64 only.
3. The first test images built from `quattro-upstream` are installed on the M2 Max, then on the M1 Pro.
4. The remaining Mac features move behind the platform detector and dispatch points: audio, Wi-Fi resume, display, video decode, the encryption lifecycle, snapshots and boot verification.
5. The generic changes are proposed to omacom/omarchy, in order: the platform detector and profiles; composable boot configuration and generic encryption fixes; the dispatch interface; the migration caller.
6. The move for existing Macs is built and tested for each kind of install.
7. After cold-boot qualification on the M1 Pro and the M2 Max, the packages are promoted to `rc` and `stable`, the stable installer catalog is published, and the move for existing Macs is switched on.

## Not in the first release

- M3 and M4 Macs, Touch ID, MLX and Secure Enclave disk encryption. Each is separate work.
- Encrypting an unencrypted Mac in place while moving it from an earlier install. It may come later as an opt-in.
- The Asahi kernel as a supported choice. Every Mac runs Aurora.
- A portable installer that runs without installing a privileged helper.
- Moving the installer's signing identity and catalog hosting to Omarchy's own. That is a later configuration change.

Known hardware issues are listed under [Hardware support]({{page:hardware}}).
