---
title: Upstream and contributing
description: How the Mac work relates to Omarchy, Asahi, Aurora and Hyprland, and where a change belongs.
section: Reference
---

A change lives as close to upstream as it can. Every layer the Mac work touches has an upstream, and each takes changes its own way.

| Layer | Upstream | How changes flow |
| --- | --- | --- |
| Desktop | [omacom/omarchy](https://github.com/omacom/omarchy) | Only platform-neutral changes go upstream: the platform detector, composable boot configuration, generic encryption and password fixes, dispatch points and one migration caller. They benefit x86 too, and do nothing on platforms without an implementation. Changes that affect every aarch64 machine are co-authored with the Omarchy Dragon (Snapdragon) maintainers. |
| Mac packages | [omacom/omarchy-mac](https://github.com/omacom/omarchy-mac) | `omarchy-mac` and `omarchy-mac-boot`, each independently versioned and tested. They stay out of any desktop submission. |
| Packages | [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs) | Mac recipes are pinned to exact omarchy-mac commits, built for aarch64 only and published to `edge` first. |
| Installer | [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer) | The macOS app, the engine overlay and the image builder |
| Kernel | [aurora-silicon/linux](https://github.com/aurora-silicon/linux) | Pull requests to the Aurora kernel tree |
| Boot, firmware, engine | [Asahi Linux](https://asahilinux.org) | `asahi-scripts` is used as Asahi ships it; `m1n1-aurora` is Asahi's m1n1 built for the Aurora kernel with the Omarchy boot logo; U-Boot is built with a silent console; the installer engine is Asahi's installer with Omarchy's patches, pinned by digest |
| Compositor | [hyprwm/Hyprland](https://github.com/hyprwm/Hyprland), [hyprwm/aquamarine](https://github.com/hyprwm/aquamarine) | Fixes are submitted upstream. An aquamarine display fix is carried for aarch64 until hyprwm releases it. |

## Naming

Identifiers owned here are named `mac`: `omarchy-mac`, `omarchy-mac-boot`. Names that belong to the Asahi project keep them: `linux-asahi`, `asahi-scripts`, `[asahi-alarm]`, `uboot-asahi`.

## Contributing

- **Bugs**: open an issue on [omacom/omarchy-mac](https://github.com/omacom/omarchy-mac/issues) with the details listed under [Hardware support]({{page:hardware}}#reporting-a-problem). Installer bugs go to [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer/issues).
- **Changes**: pull requests against `quattro-upstream` on omacom/omarchy-mac. Anything Apple-specific runs behind the platform detector and comes with a migration if it changes installed systems.
- **Packages**: pull requests against `master` on omacom/omarchy-pkgs. A new Mac recipe is aarch64-only and edge-only in its first merge.
- **This manual**: the pages live in `mac-manual/content/` on omarchy-mac. Change a page in the same pull request as the behaviour it describes.
- **Reviews**: designs and code are reviewed before merge, and boot-critical changes need cold-boot evidence from a test Mac.

The plan behind all of this is [the Apple Silicon convergence spec](https://github.com/omacom/omarchy-mac/blob/quattro-upstream/docs/apple-silicon-convergence.md).

## Licence

The Mac packages and this manual are released under the same MIT licence as Omarchy. The Asahi installer engine, m1n1 and U-Boot keep their own licences.
