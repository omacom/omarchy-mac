# Apple Silicon gap audit: #503 and quattro-upstream against mx-mac

Ported-feature ledger for ticket 03 of the Apple Silicon convergence spec (`docs/apple-silicon-convergence.md`, added by [#512](https://github.com/omacom/omarchy-mac/pull/512)). It lists every Apple Silicon feature of maralcbr/omarchy-mx-mac and says whether draft PR [#503](https://github.com/omacom/omarchy-mac/pull/503) (with the owner's review fixes) and `quattro-upstream` carry it, where it belongs and which ticket owns the rest. It builds on #503's own records (`docs/quattro-encryption-limine-source-port-2026-09-22.md`, `docs/quattro-encryption-limine-files-2026-09-22.json`), which cover the encryption/Limine slice at mx-mac `d418ab7f`; this ledger covers every spec area at mx-mac's current head.

Audited 2026-09-25 (Brisbane). Source-level comparison only: nothing here was built, installed or booted.

## Sources

| Short | Repository and ref | Commit |
| --- | --- | --- |
| `mx` | maralcbr/omarchy-mx-mac `main` | `8e70a5cdcc82` |
| `qu` | omacom/omarchy-mac `quattro-upstream` | `b4a79d83d114` |
| `503` | omacom/omarchy-mac #503 `integrate/quattro-encryption-limine` | `0d4070aeac3f` |
| `fix` | owner's review fixes on top of #503, branch `fix/pr503-review-findings` (local worktree `omarchy-mac-pr503-fixes`, not pushed) | `9d7d72816858` |
| `p65` | omarchy-mac/omarchy-pkgs-aarch64 #65 (boot recipes paired with #503) | `617a907f99a1` |
| `mxpkgs` | maralcbr/omarchy-pkgs `asahi-quattro` (mx-mac's recipes) | `7e2f6cfec1b3` |
| `ompkgs` | omacom/omarchy-pkgs `master` | `ed6a3869c73a` |

#503's runtime port stops at mx `d418ab7f` (#220) and its package port at mxpkgs `68a61cef` (#194). mx has since merged boot and hardware fixes the port does not have: #248, #250, #247, #266 (boot check, GRUB, Limine migration, keyboard), #239, #242 (audio), #260, #267 (legacy repository), and mxpkgs #202, #203, #207 (initramfs keyboard, Limine hook, edge kernel). They appear below as partial or missing.

## How to read the ledger

Status:

- **ported**: the converged tree (`qu`, `503`+`fix`, or `p65` for boot payload) has equivalent behaviour. It may still need qualification by its owner ticket.
- **partial**: some of it is there, or it is there in an older or different form.
- **missing**: not in the converged tree.
- **dropped**: intentionally not carried; the reason is given.
- **qu-only**: a `quattro-upstream` feature mx-mac lacks (listed so nothing from either side is lost).

Tag (where the item lands):

- **boot**: `omarchy-mac-boot`, the boot chain packages (Aurora, m1n1, U-Boot, Limine), the image producer and anything behind the cold-boot gate.
- **runtime**: `omarchy-mac`, or Mac-only tooling and docs in omarchy-mac that are not on the boot path.
- **generic**: upstream omarchy, omarchy-settings or shared omarchy-pkgs recipes.

Owner is the ticket number from the convergence ticket index (`.scratch/apple-silicon-convergence/README.md` in the spec work; not yet in this repository). **NEW TICKET NEEDED** marks a gap no ticket owns; proposed titles are collected at the end.

## 1. Boot chain: Limine, m1n1, U-Boot

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| B1 | Limine activation: UKI, menu, ESP deploy to `EFI/BOOT/BOOTAA64.EFI`, rollback, foreign machine-id reset, installer staging kept | ported | boot | 04, 09 | mx `install/hardware/apple/limine-boot.sh`, `bin/omarchy-mac-limine-{active,deploy}` (#211, #217-#220). 503 `packages/omarchy-mac/boot/setup/limine-boot.sh`, `boot/bin/omarchy-mac-limine-{active,deploy}` with stricter rollback (`5d4c0f8e2`, `12308e1ca`); fix `03e3fdc0a` backs up the whole GRUB directory. |
| B2 | Limine command line derived from GRUB defaults; root subvolume from fstab (ext4 roots) | ported | boot | 04 | mx `bin/omarchy-mac-limine-cmdline` (#250). 503 `boot/bin/omarchy-mac-limine-cmdline`; fix `c1b3ef005` (subvolume from fstab), `11e39ac15` (exit 100 aborts the UKI rebuild). The GRUB-defaults bridge is a documented temporary adaptation (`packages/omarchy-mac/boot/README.md`). |
| B3 | Boot update dispatcher (GRUB and Limine) | ported | boot | 04, 35 | mx `bin/omarchy-mac-boot-update` → 503 `boot/bin/omarchy-mac-boot-update`. Called by provisioning (`boot/lib/provision.sh`) and the p65 conversion hook; update-path wiring is 35. |
| B4 | GRUB console: GOP backend and unbounded root-device wait, systemd initramfs only | partial | boot | **04 (blocker)** | mx `install/hardware/apple/grub-console.sh` after #248 (`80a4c43e`) adds the wait only on a systemd initramfs, joins an existing `rootflags=` and removes it on a busybox one. 503 `boot/setup/grub-console.sh` is the older #209 version: it appends `rootflags=x-systemd.device-timeout=0` unconditionally (L11, L47-L51). mx #238/#248 found that a second `rootflags=` overrides `rootflags=subvol=@` on busybox `encrypt` Macs, which then fail to boot. #503 newly runs this leaf from `install/hardware/all.sh`. |
| B5 | Resolve the kernel's effective mkinitcpio HOOKS (preset, drop-ins, `-A`/`-S`) | missing | boot | 04, 16 | mx `bin/omarchy-hw-apple-initramfs-hooks` (#248). Needed by the B4 fix and by the boot check's busybox detection. |
| B6 | ESP discovery (`/boot/efi` or `/boot`), recorded as `ESP_PATH` | partial | boot | 45, 43 | mx `bin/omarchy-mac-esp` (#250). fix `093ab7cd8` parses every `ESP_PATH` form and the boot check reads it, but 503's Limine leaf defaults to `/boot/efi` (`setup/limine-boot.sh` L14) and `omarchy-mac-esp` is absent. Only machines with the ESP at `/boot` (older installs) are affected. |
| B7 | Limine enablement of existing GRUB Macs, retried by `omarchy update` | dropped | boot | 43, 45 | mx `bin/omarchy-mac-limine-enable`, `migrations/1790055026.sh`, `bin/omarchy-update` L94-L99 (`limine-activation.pending`). #503 scopes Limine to fresh images; its file map marks these "deferred-existing-user-migration". |
| B8 | `limine-mkinitcpio-hook` on Macs: Apple activation gate, stock mkinitcpio keeps writing `/boot` | partial | boot | **NEW TICKET NEEDED** (N1), 09 | mxpkgs `pkgbuilds/limine-mkinitcpio-hook` 1.36.0-4 (#182, #186, #203: aarch64 UKI patch, Limine hook renamed to `91-`, `limine-apple-gate`). p65 carries 1.36.0-3 with its own `0002-honor-apple-activation-before-pacman-hooks.patch` (gate execs stock mkinitcpio while dormant) and lacks #203. ompkgs has 1.39.0 for x86_64+aarch64, whose upstream already writes aarch64 UKI/EFI entries (limine-entry-tool 1.39.0 `Utility.java` L578-L583, `isSystemSupportedArch`), so only the gate and `/boot` behaviour are missing; omacom cannot carry a second package of that name. |
| B9 | `limine-snapper-sync` on aarch64 | ported | generic | 36 | mxpkgs 1.30.1; ompkgs `pkgbuilds/limine-snapper-sync` 1.32.0 already builds aarch64. |
| B10 | Silent U-Boot (`uboot-asahi`, quiet console, boot menu) | ported | boot | 07 | mxpkgs and p65 `pkgbuilds/uboot-asahi` 2026.07.asahi2-3 (quiet-console patch). Not yet in ompkgs, the target repository; publication is 07. |
| B11 | `m1n1-aurora` (Omarchy boot logo, CIO aliases) | missing | boot | 07 | mxpkgs `pkgbuilds/m1n1-aurora`; absent from p65 and ompkgs. |
| B12 | Measured m1n1/U-Boot identities and branding contract for images | partial | boot | 07, 23 | 503 `docs/quattro-encryption-limine-source-port-2026-09-22.md` ("New U-Boot/m1n1 branding and the release-product boot contract still need measured artifact identities"). |
| B13 | Installed kernel family (`linux-aurora` or `linux-asahi`) | ported | boot | 04 | mx `bin/omarchy-hw-apple-kernel` (marker file) replaced by 503 `boot/bin/omarchy-mac-kernel` (reads the pacman database, refuses ambiguity). |
| B14 | Boot check: kernel, initramfs, GRUB, m1n1, UKI and menu hash coherence | partial | boot | 35, 43, 45 | mx `bin/omarchy-apple-silicon-boot-check`. 503 `boot/bin/omarchy-apple-silicon-boot-check`; fix `f79ae2f5d` (UKI hash, kernel inside the UKI). Missing: keymap-at-prompt checks (#247, #266) and busybox `cryptdevice=` acceptance (#248). Nothing in 503 calls it (U1). |
| B15 | Retire saved `-ARCH` modules after a kernel downgrade and rebuild m1n1 | missing | boot | 35 | mx `bin/omarchy-apple-silicon-retire-saved-modules`, called from `bin/omarchy-update-aurora-repository` L535. Needed wherever a channel move or restore installs an older Aurora. |
| B16 | Direct EFI boot entry refused on Apple Silicon | ported | generic | 13 | mx `bin/omarchy-setup-direct-boot` L6-L9 and qu L8-L11 (same guard). |
| B17 | GRUB visuals: console font, theme, quiet splash | dropped | boot | none | mx `migrations/1790030337.sh`, `1790003445.sh`, `1790037110.sh`, `default/grub/omarchy/theme.txt`. GRUB is transition-only; #503 excludes font/theme/splash. mx Macs already ran them. |
| B18 | Repair GRUB kernel line on busybox `encrypt` Macs | missing | boot | 43, 45 | mx `migrations/1790226002.sh` (#248). Only machines that ran the older GRUB leaves need it. |
| B19 | aquamarine possible-CRTC re-read (third and fourth external displays) | missing | runtime | 10, 11 | mxpkgs `pkgbuilds/aquamarine` with `0001-drm-re-read-possible-CRTCs...` and `0002-drm-release-output-on-disconnect` (0002 shipped upstream in 0.15.1, so dropped per spec). Absent from ompkgs. |

## 2. Aurora kernel lanes

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| K1 | `linux-aurora` built and published per channel (stable follows rc's qualified kernel) | partial | boot | 06 | mxpkgs `pkgbuilds/linux-aurora-{stable,rc,edge}` (#199, mx #234). ompkgs `pkgbuilds/linux-aurora` is `skip_build`, channels `edge`, `rc`. |
| K2 | Edge kernel carries the macaudio headset-button patch | missing | boot | 06, 37 | mxpkgs `pkgbuilds/linux-aurora-edge/0001-ASoC-apple-macaudio-Map-headset-buttons-to-input-key.patch` (#207). |
| K3 | Aurora and m1n1-aurora as the installed default | missing | boot | 22, 23 | mx `install/omarchy-base-asahi.packages` (`linux-aurora`, `linux-aurora-headers`, `m1n1-aurora`). qu images still take stock `linux-asahi`; 503 accepts either family (B13). |
| K4 | `[omarchy-aurora]` pin to a qualified signed release, ALPM pre-transaction verify hook | dropped | boot | 30, 31, 52, 43 | mx `bin/omarchy-update-aurora-repository`, `bin/omarchy-update-aurora-verify`, `default/libalpm/hooks/01-omarchy-aurora-verify.hook`, `default/aurora-{qualified,stable}-release`. Spec replaces per-machine pins with signed omacom channels; pin policy moves to release tooling (30); mx Macs retire it in 43. |
| K5 | Channel record and lane commands (`rc`/`edge` gate) | dropped | generic | 14, 43 | mx `bin/omarchy-apple-silicon-channel`, `bin/omarchy-channel-set`, `bin/omarchy-channel-current`. qu uses upstream channels (`default/pacman/aarch64/pacman-{rc,stable}.conf`). |
| K6 | Kernel headers follow the installed kernel (DKMS, Xbox controllers) | missing | runtime | **NEW TICKET NEEDED** (N6), 45 | mx `install/helpers/optional-packages.sh` L77-L81 uses `$(omarchy-hw-apple-kernel)-headers`; `migrations/1789879296.sh` swaps Asahi headers for Aurora's. qu and 503 hardcode `linux-asahi-headers` on Apple Silicon (`bin/omarchy-install-gaming-xbox-controllers` L14-L16, `default/omarchy/omarchy-menu.jsonc` `install.gaming.xbox-controllers`), which is wrong on any Aurora install. The legacy header swap is 45. |
| K7 | M3 keeps `linux-asahi` (never Aurora) | dropped | boot | none | mx `bin/omarchy-install-asahi-fresh` (#250). M3 is out of scope in the spec. #503's merge criteria still name an M3 install (see blockers). |

## 3. Encryption: conversion, provisioning, recovery, password sync, factory reset

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| E1 | In-place LUKS conversion in the initrd | partial | boot | **04 (blocker)**, 09, 32 | mxpkgs `pkgbuilds/omarchy-mac-boot/files/usr/lib/omarchy/initcpio/omarchy-mac-encrypt*` (#155, #170). p65 carries it with a Limine-prerequisite refusal. The source is not in `quattro-upstream`, so ticket 09 cannot pin it there. |
| E2 | `install.conf` encryption handoff from the installer | partial | boot | 02, 32 | mx installer writes `install.conf`; mxpkgs `omarchy-mac-first-boot` and `omarchy-mac-encrypt` read it. p65 ports the consumers; the omacom installer extraction (2.0.4) has `InstallConf`. 32 decides the default when it is absent. |
| E3 | Owner provisioning and first-boot re-key (owner slot, kill other slots, drop `rd.luks.key`) | ported | boot | 32, 18 | mx `bin/omarchy-provision-owner` (`rekey_luks_apple`, `apple_rekey_boot`). 503 `bin/omarchy-provision-owner`, `boot/lib/provision.sh`; fix `e554b9ad0` (resume requires the recorded owner password), `8cdfcd5c3` (atomic GRUB defaults). Not yet through dispatch (20, 32). |
| E4 | Recovery passphrase | ported | generic | 33 | mx `bin/omarchy-provision-owner` L685 `generate_recovery_passphrase`, L873 `show_recovery_key`. 503 `install/provisioning/luks-recovery.sh` journals the slot, verifies the key and records acknowledgement. Visual check on an Apple VT is still open (503 source-port record). |
| E5 | Temporary install key and staged key cleanup | ported | generic | 18, 33 | mx `shred_luks_keyfiles`, `grub_drop_rd_luks_key`. 503 refuses `finished` while a staged key or `rd.luks.key=` remains. |
| E6 | Retry journals for encryption and re-key | ported | generic | 18 | mx `write_encrypt_state`, `rekey_state_put`. 503 makes them durable (file and directory sync). |
| E7 | Raw LUKS parent discovery | ported | generic | 18 | mx #196; already in qu (#494, `test/shell.d/luks-parent-detection-test.sh`). |
| E8 | Password sync between LUKS, login and root | dropped | generic | 19 | mx `bin/omarchy-drive-password` L34-L42 changes login and root before LUKS. 503 `a5fc2b8ee` removes the Mac account sync, leaving the generic LUKS-only command. Spec wants LUKS first, journaled, root volume only (19, which also fixes mx). |
| E9 | Factory reset: re-key, activate `@factory`, reset the Limine menu, verify UKI hashes, roll back | partial | boot | 34, 36 | mx `bin/omarchy-system-factory-reset`, `-finish`. 503 plus `boot/lib/factory-reset.sh`; fix `dd6026ce2`, `093ab7cd8`, `6af2a2070`, `3e374203a`, `c5f9c5864`, `82a46155d`. A reset whose factory kernel differs from `/boot` is refused (`factory-reset.sh` L55). Not through dispatch. |
| E10 | Firmware (vendorfw) ordering before cryptsetup | ported | boot | 16, 32 | mxpkgs `omarchy-vendorfw-initrd.{sh,service}`, `omarchy-vendorfw-cryptsetup.conf`; p65 carries them. |
| E11 | Keyboard and trackpad at the passphrase prompt, including dock keyboards | partial | boot | 16 | mxpkgs `files/etc/mkinitcpio.conf.d/92-omarchy-mac-hid.conf` after #202 adds `thunderbolt` and `thunderbolt_apple`; p65's copy predates #202. |
| E12 | Owner's keyboard layout at the passphrase prompt (non-Latin layouts kept out) | missing | boot | **04 (blocker)**, 16, 35 | mxpkgs `files/etc/mkinitcpio.conf.d/94-omarchy-mac-vconsole.conf` (#202; the aarch64 settings package drops upstream's `omarchy_hooks.conf`). Absent from p65, whose `91-omarchy-mac-encrypt.conf` only swaps an existing `keymap`/`consolefont` for `sd-vconsole`, so the prompt's layout depends on the HOOKS baseline. Owners with non-US Latin layouts risk a passphrase that does not type at boot. |
| E13 | Plymouth draws the prompt in the Mac initramfs | ported | boot | 16 | mxpkgs `93-omarchy-mac-plymouth.conf` (#172); p65 carries it. |
| E14 | HOOKS composition for `systemd`, `sd-encrypt` and `omarchy-mac-encrypt`; busybox lines left alone | ported | boot | 15, 16 | mxpkgs `90-omarchy-mac.conf`, `91-omarchy-mac-encrypt.conf`; p65 carries them. They must compose on the new baseline (15, 16). |

## 4. Snapper and snapshot restore

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| S1 | Snapper root config and update snapshots on Apple Silicon | ported | generic | 36 | mx `install/config/snapper.sh`, `migrations/1789999316.sh`; qu `migrations/1789148088.sh`, `test/shell.d/snapper-test.sh` (#493). |
| S2 | Limine snapshot entries and boot-and-restore | partial | boot | 36 | mx dispatch in `bin/omarchy-snapshot` (`test/shell.d/snapshot-limine-dispatch-test.sh`). 503 `bin/omarchy-snapshot` uses `limine-snapper-restore` when present; untested on a Mac image. |
| S3 | Read-only snapshot boot overlay in the initrd | ported | boot | 36 | mxpkgs `omarchy-mac-snapshot-overlay{,.service}`; p65 carries them. |
| S4 | Restore refuses a snapshot incoherent with the live `/boot` kernel | missing | boot | 36 | mx `bin/omarchy-mac-snapshot-restore` L174-L193 checks the snapshot carries modules for the `/boot` kernel (GRUB path). The Limine path has no equivalent; 503 only guards factory reset (E9). |
| S5 | GRUB-era snapshot menu, restore, `/.snapshots` subvolume, grub-btrfs | dropped | boot | 36, 43 | mx `bin/omarchy-mac-snapshot-menu`, `bin/omarchy-mac-snapshot-restore{,-finish}`, `install/hardware/apple/snapshots-subvolume.sh`, `migrations/1790009252.sh`. #503 marks them fallback-review; spec keeps them transition-only on GRUB Macs. |

## 5. Repository trust and keyring

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| R1 | Signed package repository on Apple Silicon | missing | generic | 14, 22, 52, 44 | mx `install/hardware/pacman.sh`, `default/asahi-repository-signing.asc`, `bin/omarchy-update-asahi-repository`, `migrations/1787560726.sh`. qu `install/hardware/apple/pacman.sh` and `migrations/1788200000.sh` add `[omarchy-aarch64]` with `SigLevel = Optional TrustAll`. Pre-existing on qu, not introduced by #503. |
| R2 | First-boot keyring trust | dropped | boot | 43 | mxpkgs first boot embeds and locally signs `C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC`; p65 only populates shipped keyrings (intended). 43 must remove that key from mx Macs. |
| R3 | Retire omarchy-mac's `[omarchy-aarch64]`, its conflicting packages and stale sync database | missing | generic | 44, 14, 43 | mx `bin/omarchy-update-asahi-legacy-repository`, `migrations/1790256699.sh` (#260, #267). qu does the opposite (R1): an mx Mac that ran qu's leaf would get the unsigned repository back, so 43 must keep it out. |
| R4 | Candidate download and verification | dropped | boot | 22, 30 | mx `bin/omarchy-pkg-repository-{download,verify}-candidate`. Moves to candidate and release tooling. |
| R5 | Signed bundle updater (`omarchy-dev`, `omarchy-settings-dev`) | dropped | runtime | 43 | mx `bin/omarchy-update-asahi-bundle`. Retired by the mx adapter. |

## 6. First boot, deferred steps and image build

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| F1 | Owner created at first boot (tty1 wizard; SDDM held back) | ported | boot | 32, 41 | mx `bin/omarchy-provision-owner`, `bin/omarchy-install-asahi-fresh --deferred-user`. p65 `usr/lib/systemd/system/omarchy-provision-owner.service.d/20-mac-first-boot.conf`, `sddm.service.d/20-mac-first-boot.conf`. |
| F2 | All model-specific hardware leaves deferred to first boot on the real Mac | partial | boot | 41 | mx `bin/omarchy-mac-run-deferred-steps`, `install/helpers/mac-image-build.sh` L70-L90, `install/hardware/all.sh` L1-L8. p65 `usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot` accepts only `install/hardware/apple/limine-boot.sh`. |
| F3 | Image-build platform identity without the host device tree | missing | boot | 24 | mx `install/helpers/mac-image-build.sh` (`OMARCHY_MAC_TARGET=generic-apple-silicon`). 503's record says the builder still needs an explicit build-only detection context. |
| F4 | Fresh installer: offline, resumable checkpoints with field-level diagnostics, `update-m1n1`, boot check | partial | boot | 21, 23 | mx `bin/omarchy-install-asahi-fresh` (#246, #250). Not ported as a command by design; its contract is translated into the installer#2 builder. |
| F5 | Platform stack contract and verifier | dropped | boot | 23, 24 | mx `install/apple-silicon-platform-stack.json`, `bin/omarchy-apple-platform-stack-verify`. Replaced by image inspection (23) and the target manifest (24). |
| F6 | Image finalization: markers, factory seal, builder identity scrub | partial | boot | 21, 23 | mxpkgs `files/usr/bin/{mac,apple}-image-finalize`. p65 excludes them; installer#2 has the `asahi_limine.py` finalizer behind the schema-4 guard. |
| F7 | Adoption of image-written boot files into the boot package | dropped | boot | 43, 09 | mx `bin/omarchy-update-apple-boot-admission`, `bin/omarchy-update-system-pkgs`. Fresh images install the package; mx Macs need it in 43; 09 retires the old names. |
| F8 | macOS installer 2.0.10 (model refusal, engine diagnostics, Stable default, resize during download) | missing | boot | 01, 02 | mx `apps/omarchy-apple-installer` (#223, #228, #259, #262). omacom installer is at 2.0.4. mx #265 (retry a dropped payload download) merged after the 2.0.10 release; 02 should confirm it is included. |

## 7. Audio

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| A1 | Asahi audio stack: `asahi-audio`, `speakersafetyd`, `pipewire-pulse`, `rtkit` | ported | runtime | 37 | mx `install/omarchy-base-asahi.packages`, `migrations/1787552067.sh`. qu `install/hardware/apple/audio.sh`, `migrations/1788200002.sh`, `1789136142.sh` (desktop leaf, not yet in `omarchy-mac`). |
| A2 | `alsa-ucm-conf-asahi` so the speaker path exists | missing | runtime | 37 | mx `install/omarchy-base-asahi.packages`, `migrations/1790197726.sh` (#239). qu `audio.sh` does not install it. |
| A3 | Speaker amplifiers kept powered (WirePlumber no-suspend) | missing | runtime | 37 | mx `default/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf`, `etc/wireplumber/...`, `install/hardware/apple/fix-speaker-pop.sh`, `install/user/hardware/apple/fix-speaker-pop.sh`, `migrations/1788345489.sh`. |
| A4 | Remove the `software-dsp.lua` overlay that hangs WirePlumber | dropped | runtime | none | mx `migrations/1790225826.sh` (#242). qu never shipped the overlay; mx Macs already ran the removal. |

## 8. Wi-Fi

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| W1 | Intel/T2 Broadcom WPA workaround skipped on Apple Silicon | ported | generic | 13 | mx and qu `install/hardware/apple/fix-brcmfmac-supplicant.sh`, `migrations/1789172112.sh`. |
| W2 | iwd as the NetworkManager Wi-Fi backend | ported | runtime | 38 | mx `install/hardware/network.sh` L2-L7 writes `/etc/NetworkManager/conf.d/wifi_backend.conf`. qu ships it from the package (`packages/omarchy-mac/vendor/NetworkManager/conf.d/20-omarchy-mac-wifi.conf`) and retires that exact legacy file (`packages/omarchy-mac/legacy/wifi_backend.conf`); 38 keeps administrator edits. |
| W3 | Wi-Fi health in the Apple debug report | missing | runtime | 29 | mx `bin/omarchy-debug-apple`. |

## 9. Display, notch, cursor, backlight, ambient light and input

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| D1 | Software cursor on Apple Silicon (DCP cursor lag) | partial | runtime | 39 | mx `default/hypr/apple.lua` sets `no_hardware_cursors = true` on every Apple Silicon Mac. qu `install/user/hardware/apple/electron-gl.sh` L40-L51 sets it only when there is no render GPU. |
| D2 | Display backlight (internal panel; Studio/XDR through `asdcontrol`) | ported | generic | 39 | mx and qu `bin/omarchy-brightness-display{,-apple}` identical; ompkgs `asdcontrol` builds aarch64. |
| D3 | Tap-to-click off for `apple-mtp-multi-touch` and `apple-spi-trackpad` | ported | generic | none | mx and qu `default/hypr/input.lua` L78-L79. |
| D4 | Function keys: media keys first on Apple keyboards | partial | runtime | **NEW TICKET NEEDED** (N2) | mx `install/hardware/fix-fkeys.sh` and `migrations/1790305681.sh` use `fnmode=3` (#266; external non-Apple `hid_apple` boards keep F-keys first). qu `migrations/1789132067.sh` uses `fnmode=1`. Policies differ; no ticket owns the decision. |
| D5 | HID early-load for the internal keyboard and trackpad | ported | boot | 16 | mx `install/hardware/apple/fix-asahi-hid-race.sh`, `migrations/1787497040.sh`; qu same leaf and `1788200001.sh`; p65 `92-omarchy-mac-hid.conf`. Two writers (`apple_hid_modules.conf` from the leaf, `92-` from the package) must collapse to the package (16). |
| D6 | `/dev/btrfs-control` before tmpfiles in the systemd initrd | ported | boot | 09, 16 | mx `install/hardware/apple/fix-asahi-btrfs-race.sh`, `migrations/1789107528.sh`; p65 `files/etc/systemd/system/kmod-static-nodes.service.d/10-before-tmpfiles-setup-dev.conf`. |
| D7 | Greeter waits for the Apple display controller before starting | missing | runtime | 39 | mx `etc/systemd/system/sddm.service.d/10-wait-for-drm.conf` (simpledrm hands over to apple-drm about 3 s into boot; a greeter bound to simpledrm freezes). Absent from qu. |
| D8 | Greeter keeps keyboard focus when late displays open login windows | missing | generic | 39 | mx `default/sddm/hyprland.lua` L21-L68 (#109). qu `default/sddm/hyprland.lua` lacks it. |
| D9 | Other Apple gates already on qu: `vulkan-asahi`, MTP trackpad detection, rustup over curl, arm64 Node for offline mise | ported | generic | 13 | qu `install/hardware/vulkan.sh` L13-L15, `bin/omarchy-hw-touchpad` L5-L7, `bin/omarchy-install-dev-env` L126, `install/user/mise-work.sh` L21-L33; mx has the same gates. |

## 10. Battery

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| P1 | Battery status on `macsmc-battery` (power sign, charge thresholds) | ported | generic | none | qu `bin/omarchy-battery-status` is ahead of mx (signed `power_now`, thresholds from the resolved battery). |
| P2 | Battery and AC checks in the Apple debug report | missing | runtime | 29 | mx `bin/omarchy-debug-apple` L247-L264. |

## 11. Video decode

mx-mac has no hardware video decode. See Q5 for the `quattro-upstream` feature.

## 12. Update path and migrations

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| U1 | Post-update boot verification blocks completion and reboot | missing | boot | 35 | mx `bin/omarchy-update` L101-L135 (`omarchy-update-aurora-repository --complete` runs the boot check; `aurora_unverified` withholds `omarchy-update-restart`). 503 ships the boot check with no caller. |
| U2 | Per-migration Apple Silicon review policy (run, skip, handled) | dropped | generic | 13, 42, 49 | mx `bin/omarchy-migrate` L70-L160. qu migrations gate themselves on the detector; spec adds a lint (13) and one dispatch migration (49). mx migration history differences are 43's problem. |
| U3 | Stock Arch `~/.bashrc` on Mac accounts | missing | generic | 14 | mx `migrations/1790226283.sh` (#243). Root cause: the aarch64 settings package drops the Omarchy skeleton; runtime profile selection (14) removes it. |
| U4 | Default packages missing from the Asahi set | dropped | generic | 14 | mx `migrations/1788486400.sh`. Superseded by composed platform lists (14). |
| U5 | zram and systemd-oomd tuning on Apple Silicon | partial | generic | 14 | mx `default/systemd/zram-generator.conf.d/90-omarchy.conf`, `install/config/enable-services.sh` L33-L35. qu skips oomd the same way; the aarch64 settings package strips the reclaim tunings (open omarchy-mac#490 against `quattro`). |
| U6 | Existing-user boot migrations (Limine switch, busybox repair, header swap) | dropped | boot | 42-45 | See B7, B18, K6. Deferred by #503 by design. |

## 13. Optional packages

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| O1 | Menu availability honours aarch64 builds | ported | generic | 12, 14 | mx `install/helpers/optional-packages.sh`; qu `bin/omarchy-pkg-available`, `test/shell.d/optional-availability-test.sh` (different mechanism, same outcome). |
| O2 | Prebuilt `voxtype-bin` on aarch64 | ported | generic | none | mx #245; qu `bin/omarchy-voxtype-install`; ompkgs `voxtype-bin` builds aarch64. |
| O3 | Tensaku screenshot editor | ported | generic | none | mx #244, `migrations/1790226271.sh`; qu `install/omarchy-base.packages`; ompkgs `tensaku` builds aarch64. |
| O4 | Obsidian from the signed repository | partial | generic | 14, 44 | mx replaces `obsidian-appimage` with the packaged `obsidian` (#260). qu `migrations/1789146111.sh` installs the AppImage build. ompkgs `obsidian` builds aarch64. |
| O5 | Optional aarch64 apps from a signed source (Cursor, 1Password, share picker, Widevine) | partial | generic | 14 | qu leaves pull them from unsigned `[omarchy-aarch64]` (`install/hardware/apple/pacman.sh` header). ompkgs now builds `cursor-bin`, `1password`, `hyprland-preview-share-picker` for aarch64; `widevine` is not in ompkgs (mx takes it from the Asahi repositories). |

## 14. Hardware validation and CI

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| H1 | VM acceptance with hashed evidence (fresh install, image) | missing | boot | 27, 28 | mx `test/vm/asahi-fresh/`, `test/vm/mac-image/` (#255, #258). qu has none; omarchy-mac #504 (draft, based on #503's branch) adds an authenticated private-image harness that 28 must reconcile with the relocated one. |
| H2 | Hardware validation runbook and `omarchy-debug-apple` | missing | runtime | 29 | mx `docs/apple-silicon-hardware-validation.md`, `bin/omarchy-debug-apple`, `test/shell.d/debug-apple-test.sh`. |
| H3 | Package resolution, install transactions, boot-check integration in a container | missing | generic | 12 | mx `test/packages-resolve`, `test/packages-install-transaction`, `test/prepare-alarm-container`, `test/generate-optional-transactions`, `test/aurora-integration`, `.github/workflows/packages.yml`, `optional-packages.yml`. |
| H4 | CI running the runtime and package suites on every PR | missing | generic | **NEW TICKET NEEDED** (N3) | mx `.github/workflows/tests.yml`, `release.yml`. `quattro-upstream` has no `.github/workflows` at all; `packages/omarchy-mac/test/all` and `boot/test/all` run only by hand. |
| H5 | Release orchestration and Aurora pin tooling | missing | runtime | 30, 31 | mx `docs/apple-silicon-deployment.md`; mxpkgs `bin/asahi-release`. |
| H6 | Release records and evidence manifests | missing | runtime | 29 | mx `docs/releases/`, `evidence/`. |
| H7 | Mac user manual and documentation site | missing | runtime | **NEW TICKET NEEDED** (N4) | mx `docs/site/`, `manual/`, `.github/workflows/pages.yml` (#215, #252). Spec puts Mac documentation in omarchy-mac; 29 covers only the validation runbook. |

## 15. quattro-upstream features mx-mac lacks

Kept on the converged path; none needs porting from mx.

| ID | Item | Status | Tag | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| Q1 | Microphone array mapping, gain persistence, headset priority | qu-only | runtime | 37 | qu `packages/omarchy-mac/bin/omarchy-audio-asahi-mic-map`, `vendor/systemd/user/omarchy-asahi-mic.service`, `share/wireplumber/wireplumber.conf.d/asahi-headset-mic.conf`. |
| Q2 | Wi-Fi resume recovery (restricted `brcmfmac` reload after s2idle) | qu-only | runtime | 38 | qu `packages/omarchy-mac/bin/omarchy-wifi-resume-fix`, `vendor/systemd/system/omarchy-wifi-resume-fix.service`. BCM4388 coverage is open as omarchy-mac#465 against `quattro`. |
| Q3 | Notch strip (`appledrm show_notch=1`) | qu-only | runtime | 39 | qu `packages/omarchy-mac/vendor/modprobe.d/asahi-notch.conf`, `migrations/1789132600.sh`. |
| Q4 | Keyboard backlight from the ambient light sensor | qu-only | generic | 39 | qu `bin/omarchy-brightness-keyboard-auto`, `default/systemd/user/omarchy-brightness-keyboard-auto.service`. |
| Q5 | Hardware video decode (AVD firmware, VA-API) | qu-only | runtime | 40 | qu `install/hardware/apple/video-decode.sh`, `migrations/1789135902.sh`, packages from unsigned `[omarchy-aarch64]`. ompkgs now has `avd-fw` and `libva-v4l2_request-avd` (aarch64). |
| Q6 | Natural scrolling on the Apple trackpad | qu-only | runtime | 39 | qu `install/user/hardware/apple/touchpad.sh`, `migrations/1789135950.sh`. |
| Q7 | Electron software GL when there is no render GPU | qu-only | runtime | 13 | qu `install/hardware/apple/electron-gl.sh`, `bin/omarchy-cmd-electron-gl-wrap`, `migrations/1789138445.sh`. |
| Q8 | Steam through FEX | qu-only | generic | 14 | qu `migrations/1789522888.sh`; ompkgs `omarchy-steam-fex`. |
| Q9 | Setup entrypoints that retire exact generated files | qu-only | runtime | 37, 38 | qu `packages/omarchy-mac/bin/omarchy-mac-setup-{system,user}`, `packages/omarchy-mac/legacy/`, `migrations/1789780917.sh`. |

Other Apple fixes are open against omarchy-mac `quattro` rather than `quattro-upstream` (#434, #462, #465, #478, #481, #486, #489, #490, #491, #498). They are outside this audit's sources; triage is proposed as N5.

## Must fix before #503 merges (input to ticket 04)

1. **Push and fold in the owner's fixes.** `fix/pr503-review-findings` (15 commits to `9d7d72816858`) exists only in the local worktree. The rows that cite `fix` (B1, B2, B6, B14, E3, E9) assume it.
2. **Port mx #248 into the GRUB console leaf (B4, B5).** #503 runs `boot/setup/grub-console.sh` from `install/hardware/all.sh` on every Apple hardware setup and appends a second `rootflags=` unconditionally. On a busybox `encrypt` Mac that overrides `rootflags=subvol=@` and the Mac does not boot. Take mx `80a4c43e`'s systemd-only gating and `bin/omarchy-hw-apple-initramfs-hooks` with their tests.
3. **Move the `omarchy-mac-boot` payload into `quattro-upstream` (E1) at mx's current revision (E11, E12).** Ticket 04 requires the boot package to build from source in `quattro-upstream`, and 09 pins that commit. Today the initcpio hooks, first boot, drop-ins, presets and ALPM hook live only in p65 `pkgbuilds/omarchy-mac-boot/files/`, which predates mxpkgs #202. Take `94-omarchy-mac-vconsole.conf`, the dock keyboard modules and #202's ALPM trigger line for `94-` (`91-omarchy-mac-boot-initramfs.hook`) with it. Without the fragment the prompt's layout depends on the HOOKS baseline (`91-omarchy-mac-encrypt.conf` only swaps an existing `keymap`/`consolefont` for `sd-vconsole`), so owners with non-US Latin layouts risk a passphrase that does not type at boot.
4. **Make the new hard dependency on `omarchy-mac-boot` installable, or sequence around it.** After #503, `omarchy-provision-owner` (503 L1333-L1338) and `omarchy-system-factory-reset` (L580-L585) exit on any Apple Silicon machine without the package, encrypted or not. The `install/hardware/apple/{grub-console,limine-boot}.sh` wrappers also return 1 when `/usr/lib/omarchy-mac/boot` is absent. `install/omarchy-apple.packages` names only `omarchy-mac`. Add `omarchy-mac-boot` to the Apple list. Don't publish a post-#503 runtime to testers before 09 publishes the boot package.
5. **Replace #503's merge criteria with ticket 04's.** The PR body asks for a complete candidate transaction, VM boots and an M3 reinstall before merge. The spec lands #503 first, then qualifies on the M2 Max and M1 Pro (22, 25, 26), and M3 is out of scope (K7). This needs the owner's and Scott's agreement.
6. **Test the tree that will merge.** #503 is 6 commits behind `quattro-upstream` (docs only: #495, #499, #508); `git merge-tree` shows no conflicts with or without the fixes. Run ticket 04's checks on the combined tree (boot package build and `boot/test/all`, runtime suite as non-root) and record the tested revision and the review on the PR.

Deferred to named tickets (not blocking #503): U1 and B15 (35), E8 (19), E9 cross-kernel reset (34, 36), S4 (36), R1 and R3 (14, 44), F2 (41), E2 (32), B8 (N1), K6 (N6), B10 and B11 (07), K1 to K3 (06, 22, 23), and the audio, Wi-Fi, display and video rows (37 to 40).

## Proposed new tickets

| ID | Proposed title | Tag | Covers |
| --- | --- | --- | --- |
| N1 | Apple activation gate in omacom `limine-mkinitcpio-hook` | boot | B8. Carry an activation gate (mxpkgs `limine-apple-gate` or p65's `0002` patch) in the shared recipe, inert on x86 and non-Apple aarch64. Whichever gate is chosen, keep #203's behaviour: stock mkinitcpio keeps `/boot` current after activation too (p65's patch only falls back to it while dormant). Upstream 1.39.0 already writes aarch64 UKIs, so the old aarch64 UKI patch is not needed. Lands before 09's boot package depends on it. |
| N2 | Converge the Apple keyboard function-key mode | runtime | D4. Pick `fnmode=1` or `fnmode=3`, move it into `omarchy-mac`, keep owners' explicit choices, rebuild the initramfs once. |
| N3 | CI for `quattro-upstream`: runtime suite and package tests on every PR | generic | H4. Run `test/all` as non-root plus `packages/omarchy-mac/test/all` and `boot/test/all`. |
| N4 | Mac user documentation home in omarchy-mac | runtime | H7. Move the mx manual/site content that still applies. |
| N5 | Triage Apple fixes open against omarchy-mac `quattro` and retarget them to `quattro-upstream` | runtime | The open `quattro` PRs listed in section 15. |
| N6 | Pick kernel headers from the installed Apple kernel | runtime | K6. Replace the hardcoded `linux-asahi-headers` in the Xbox controller install and menu with the installed kernel's pkgbase (`omarchy-mac-kernel`), with Aurora and Asahi fixtures. |
