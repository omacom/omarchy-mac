# Apple Silicon package assessment for the M3 Pro display and update failures

This machine is an Apple MacBook Pro 14-inch, M3 Pro (November 2023), device tree `apple,j514s` / `apple,t6030`. The running kernel is `linux-asahi 7.2.12.asahi2-1`. The notes below separate fixes that are already in this checkout from work that would mean building or republishing an aarch64 package. Token figures are estimates of agent work (context, tool output, and retries), not a bill from a provider. A focused change that already has a PKGBUILD is tens of thousands of tokens. A driver bring-up that needs repeated boots is past a million and still needs a person at the machine.

## Already fixed here without a new package

Qt 6.12 adds a `QtQuick` type named `Color`. It shadowed `qs.Commons`'s `Color` singleton, so `Color.bar`, `Color.menu`, and the rest were undefined. The bar drew nothing and Super+Space opened a black layer. The shell in this checkout now registers that singleton as `ShellColor` (`shell/Commons/qmldir`) and reads `ShellColor.*`. Stock `quickshell 0.3.2-1` from Arch Linux ARM is enough. No rebuild.

`omarchy update` on aarch64 was also aborting before any upgrade because `install/helpers/arm-package-sources.sh` asked pacman for `omarchy/hyprtoolkit` and `omarchy/hyprland-guiutils`, and `pkgs.omarchy.org/edge/aarch64` no longer publishes those two. The helper now selects `omarchy/<name>` only when the synced `[omarchy]` database lists it. On this machine that is `omarchy/hyprland` only. `hyprtoolkit 0.6.0-1` and `hyprland-guiutils 0.2.2-4` stay on the `extra` builds already installed, which match `libaquamarine.so=14` and `libhyprtoolkit.so=6`. A dev checkout that cannot fast-forward onto its upstream no longer aborts the rest of `omarchy update`.

`omarchy-pkg-add` already skips names that are not in the configured repos. The only foreign package installed is the locally built `omarchy-mac-keyring`, and `yay -Qua` reports nothing to upgrade.

## Packages that look missing but already have an aarch64 build

| Package | What this machine has | Republish or rebuild? |
| --- | --- | --- |
| `hyprtoolkit`, `hyprland-guiutils` | `extra` has compatible builds. Edge aarch64 does not list them. | No, unless edge's Hyprland later requires an Omarchy-only SONAME. Restoring the edge pipeline is a package-repo change, not a port. About 40k to 120k tokens if the existing `omarchy-pkgs` PKGBUILDs still compile, and 150k to 400k if a SONAME mismatch has to be chased. |
| `quickshell` (Omarchy build) | Edge already publishes `quickshell 0.3.2.r7.g2b4501a-3` for aarch64. It carries the Qt 6.11 import patch. Arch's `0.3.2-1` does not. | No rebuild to obtain the binary. Adopting it (open omarchy-mac PR 746) is policy and a migration: about 80k to 200k tokens, including tests. Each later Qt bump in Arch Linux ARM needs a matching Omarchy rebuild because Quickshell uses Qt private QML headers. A clean bump is about 40k to 100k tokens. The `ShellColor` rename makes that pin unnecessary for the shell itself. |
| `hyprland` | Edge has `0.56.2-7` for aarch64. This machine still has `extra`'s `0.56.2-4`. | No port. The next update can take the edge build. |
| `foot` | `foot 1.28.0-2` from the regular repos. Kitty, Ghostty, and Alacritty are not installed. | Terminal text glitches are not a missing terminal package. |

`install/omarchy-aarch64-unavailable.packages` still lists `obs-studio`, `dotnet-runtime`, `pinta`, `obsidian`, and `qemu-user-static-binfmt`. None of those is the bar, the menu, the cursor, or the terminal. `qemu-user-static-binfmt` is the one that is actually absent as a static ARM build: Arch Linux ARM ships dynamic `qemu-user-binfmt` only. Replacing the static helper is a small PKGBUILD change if upstream still builds the static binary, about 30k to 80k tokens, and it does not affect this display bug.

## The jitter, trails, and terminal text are a missing M3 display and GPU stack

`/dev/dri` contains only `card0`, a `simpledrm` framebuffer (`104600a2880.framebuffer`). There is no `renderD128`. `omarchy-hw-render-gpu` exits 1, and `~/.config/hypr/looknfeel.lua` therefore forces software cursors. The device tree has no `dcp@`, `gpu@`, or `display-subsystem` node. The installed `appledrm.ko` matches `apple,dcp` and `apple,t6020-dcp`. It does not match `apple,t6030-dcp`, and nothing in this tree gives it a device to bind. Mesa's `asahi_dri.so` and `vulkan-asahi` are installed and idle.

That is why the panel is stuck on the boot framebuffer at 3024x1890 (the notch is cropped out of the 3024x1964 panel), the pointer is drawn in software and leaves trails, and damage updates smear text in foot. Hyprland is compositing through a dumb framebuffer, not the Apple display controller.

This is not an "aarch64 rebuild of an x86 package". `linux-asahi`, `m1n1 1.9.9-1`, and `mesa 1:26.2.5-1` are already aarch64. Upstream Asahi's M3 Pro device tree in mainline-style trees is still the boot framebuffer only. The stack that actually brings the panel up is the Aurora one, demonstrated on this same model (`apple,j514s`) in [omacom/linux-aurora#138](https://github.com/omacom/linux-aurora/issues/138):

- `m1n1-aurora` (the report used `1.6.1.aurora17-5`) adds the t6030 display handoff and the `dcp@` nodes
- `linux-aurora` (the report used `7.1.12.aurora2`) binds `apple-t6030-display` and the asahi GPU
- `mesa-m3` (the report used `26.1.4.m3.2-5`) creates `/dev/dri/renderD128`
- Result on that machine: eDP-1 at 3024x1964 and a real GPU, with Hyprland still alive after 15 seconds

Those packages are already built for aarch64 and published as GitHub release artifacts from `omacom/linux-aurora`, installed by `install-aurora-sep.sh`. They are not in this machine's pacman repos (`pacman -Ss linux-aurora` and `mesa-m3` return nothing).

Two different costs:

- Switching this install onto those published packages is medium, not a from-scratch port. About 150k to 400k tokens to wire the installer, the m1n1 handoff flag, and the pacman ignore rules Aurora's own installer had to patch (it otherwise treats held `hyprland` / `hyprtoolkit` / `hyprland-guiutils` as pending upgrades). The risk is not tokens. Replacing stage-1 `m1n1` and the kernel can leave Linux unbootable until the machine is recovered from macOS. That needs a person and a known-good macOS install. It was not applied here.
- Rebuilding that display and GPU support inside `linux-asahi` and stock `m1n1` is a driver and firmware bring-up. The device tree, DCP handoff, PMP values, and GPU init data are M3-specific. An agent can mirror Aurora's tree, but proving it needs repeated reboots on this hardware. A realistic pass is 0.5M to 2M tokens and can still fail closed, because a wrong early-boot image is not something to iterate on blindly. Do not start that as a packaging exercise. Consume Aurora's published aarch64 packages or wait until Asahi's own `m1n1` and kernel describe t6030's display controller.

## What not to repackage for these symptoms

Rolling Qt back to 6.11 avoids the `Color` clash and breaks packages built against Qt 6.12 (`omawrite` 0.7.x looks for `Qt_6.12`). The singleton rename is the smaller fix. Building a private Qt 6.11 stack for aarch64 would be a large, ongoing fork: several hundred thousand tokens for the first bootstrap and again on every security update.

`obs-studio`, `pinta`, `obsidian`, and `dotnet-runtime` have had historical ARM build failures. Current repos may now have binaries. Qualifying each one is a separate install-and-launch check, roughly 20k to 60k tokens per application, and none of them paints the bar or the cursor.
