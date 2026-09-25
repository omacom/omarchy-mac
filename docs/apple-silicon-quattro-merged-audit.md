# Apple Silicon work merged on `quattro`: audit against quattro-upstream

Ticket 61 of the Apple Silicon convergence spec (`docs/apple-silicon-convergence.md`, [#512](https://github.com/omacom/omarchy-mac/pull/512)). Every PR merged into omacom/omarchy-mac `quattro` is classified against `quattro-upstream`: present, superseded by the convergence design, missing, or not Apple Silicon work. Missing items name their owning ticket or a proposed one, with the mx-mac status. It follows up the triage of open `quattro` PRs ([#521](https://github.com/omacom/omarchy-mac/pull/521), `docs/apple-silicon-quattro-pr-triage.md`), whose notes asked for this sweep, and the gap audit against mx-mac ([#513](https://github.com/omacom/omarchy-mac/pull/513), `docs/apple-silicon-gap-audit.md`). Rows already covered there are cross-referenced by their IDs (U5, Q4, #367 and so on), not repeated.

Audited 2026-09-25 (Brisbane) from source only: nothing was built, installed or run on a Mac. No PR was commented on, labelled or retargeted.

## Sources

| Short | Repository and ref | Commit |
| --- | --- | --- |
| `quattro` | omacom/omarchy-mac `quattro` | `e77295a9f8ab` |
| `qu` | omacom/omarchy-mac `quattro-upstream` | `b4a79d83d114` |
| `503` | omacom/omarchy-mac draft [#503](https://github.com/omacom/omarchy-mac/pull/503) `integrate/quattro-encryption-limine` | `0d4070aeac3f` |
| `p65` | omarchy-mac/omarchy-pkgs-aarch64 #65 (boot recipes paired with #503) | `617a907f99a1` |
| `mx` | maralcbr/omarchy-mx-mac `main` | `1323a7affecc` |
| `ompkgs` | omacom/omarchy-pkgs `master` | `ed6a3869c73a` |
| `inst2` | omacom/omarchy-mac-installer #2 `integrate/private-limine-installer` | `5274846c24c8` |
| `upstream` | omacom/omarchy `quattro` | `c3e67f5d4050` |

Ticket numbers are from the convergence ticket index (`.scratch/apple-silicon-convergence/README.md` in the spec work).

## Scope

- `qu` shares no Mac commits with `quattro`. It was distilled onto upstream Quattro (#11845) on 2026-09-14 to 09-17, first published at `350c4655`, and its history was cleaned on 2026-09-19. The git merge-base is an upstream commit (`b686ed892`, omacom/omarchy#9267, 2026-08-30), so `git log origin/quattro-upstream..origin/quattro` lists the whole fork: 767 commits, 564 without merges.
- The distillation is selective, not a cut at one commit. `qu` carries #403 (merged 2026-09-12) but not #387 (merged the same day), and nothing merged after #426.
- So the window is every PR merged into `quattro` on GitHub: 72 PRs, #184 to #497, 2026-08-22 to 2026-09-23. Bundles (#377, #435) are split into their commits where the parts differ, and the closed PRs that landed through #377 (#360, #372 to #376) are covered with it. The Codeberg-era merges (#150 to #161, 2026-08-07 to 08-22) and the one direct push (`739eb5a32`) are classified at bundle level at the end. The upstream syncs #233 and #308 carry upstream content and are listed as not Apple.

## How to read this

- **Present**: `qu` has equivalent behaviour, possibly reworked. The evidence cell names the `qu` commit or file.
- **Superseded**: the convergence design replaces it; the spec section is cited. *Legacy* marks changes that still shape machines on the `quattro` path, which the legacy adapter (42 to 45) starts from.
- **Missing**: not on `qu` and still needed. Owner is a ticket, or a proposed ticket (M1 to M3, at the end).
- **Not Apple**: generic desktop, test or repository work.

## Summary

- 72 PRs: 26 present, 31 superseded, 5 missing, 10 not Apple. Each PR is counted once under its main status (#435 and #389 as superseded, #229 and #377 as present); parts that differ appear in the other tables. Two of those parts are missing: #435's fresh-install zram default and #389's setup-failure message.
- Missing with an existing owner: #432 (14, same fix as triage #367), #435 fresh-install zram (14, gap audit U5), #496 (40).
- Missing with a proposed ticket: #497 charge limit (M1); #483, #474 and #389's logging hunk (M3, generic fixes for omacom/omarchy).
- Bugs present in the converged source (from the code and the PRs' reports, not reproduced here): Brave on a Mac finds no Widevine CDM, so DRM sites fail (#474); Voxtype setup tries to enable a Vulkan backend the aarch64 package does not ship and prints an error (#483); first-run stays incomplete while omacom's `omarchy-settings` omits the keyboard ALS unit (#432); fresh Mac images get no zram configuration (#435, U5).
- The legacy cohort differs from what 44 and 45 assume. Since #155 the `quattro` guided installer encrypts by default, with busybox `encrypt`, `cryptdevice=` and `/boot` on the ESP; rc4 added a fork signing key to pacman's trusted keys. See the legacy findings and M2.
- mx-mac has none of the missing items: no charge-limit command, the same Brave and Voxtype bugs, no ALS or video decode, and no setup-failure message. mx does ship a zram drop-in on aarch64.

## Missing on quattro-upstream

| PR | Change | `qu` | `mx` | Owner | Notes |
| --- | --- | --- | --- | --- | --- |
| [#497](https://github.com/omacom/omarchy-mac/pull/497) | `omarchy battery charge limit [80\|100]`: shows or sets the `macsmc-battery` charge thresholds (80 restarts at 75, 100 restores full charge) through `sudo tee`, verifies the SMC took it; manual entry in `manual/36-system-sleep.md` | Absent. `bin/omarchy-battery-status` L90-L93 only reads thresholds (UPower first; triage #356) | Absent; `bin/omarchy-battery-status` L82-L83 reads them | **M1** | upstream has no setter; open generic panel PRs omacom/omarchy#11792 and #13205 use UPower. Whether the SMC keeps the limit across reboot and shutdown is unverified. |
| [#474](https://github.com/omacom/omarchy-mac/pull/474) | Link `/opt/WidevineCdm/chromium` into `/opt/brave-bin` at install and by migration, so Brave finds the system CDM | Absent; bug present. `migrations/1789155585.sh` installs `widevine` on Apple Silicon, `omarchy-menu.jsonc` L219 offers Brave on aarch64, and `bin/omarchy-install-browser` L60-L65 never links the CDM | Absent; same bug (`install/omarchy-base-asahi.packages` L14 installs `widevine`) | **M3** (nearest 14, O5) | No-op without the `widevine` package, so it can go upstream as is. Check Brave Origin (`brave-origin-bin`) too; the PR covers `brave-bin` only. |
| [#483](https://github.com/omacom/omarchy-mac/pull/483) | Enable Voxtype's GPU backend only when `/usr/lib/voxtype/voxtype-vulkan` exists, not whenever a Vulkan runtime does | Absent; bug present. `bin/omarchy-voxtype-install` L21-L22; ompkgs `voxtype-bin` ships the Vulkan binary only in `source_x86_64` (L50-L56), not `source_aarch64` (L101) | Absent; same code (`bin/omarchy-voxtype-install` L45-L47) | **M3** | Generic aarch64: any machine with Vulkan and the aarch64 package hits it. Same code upstream. |
| [#496](https://github.com/omacom/omarchy-mac/pull/496) | Comment: `avd-fw` comes from Asahi ALARM, `libva-v4l2_request-avd` from omarchy-aarch64 | Absent. `install/hardware/apple/video-decode.sh` header still says only omarchy-aarch64 carries both | n/a (no video decode) | 40 | Comment only. Ompkgs now builds both (gap audit Q5); 40 settles the signed source and rewrites the comment. |
| [#432](https://github.com/omacom/omarchy-mac/pull/432) | Ship `omarchy-brightness-keyboard-auto.service` in the Mac settings build and repair the dangling wants link left by the first ALS migration | Latent. `install/user/first-run/enable-user-units.sh` L12-L22 enables the unit under `set -euo pipefail`; ompkgs `omarchy-settings` installs user units by name (L178-L191) without it; `migrations/1789135842.sh` L16 falls back to `ln -sfn`, which leaves a dangling link | n/a (Q4 is `qu`-only) | 14 (with 39 for Q4) | Same gap as triage #367. The build-script half is quattro-only; the migration's preserve-mask and retry rules are the reference for a `qu` repair. |
| [#435](https://github.com/omacom/omarchy-mac/pull/435) `eda3a6db5` | Write the zram default during fresh ARM system setup (`install/hardware/zram.sh`, `install/helpers/zram.sh`), because fresh installs get completed migration markers | Absent. `install/config/enable-services.sh` L19-L23 says the Apple install ships no zram; ompkgs `omarchy-settings` installs the drop-in only on x86_64 (L197-L199) and removes the config on aarch64 (L228); `inst2` deletes archinstall's `/etc/systemd/zram-generator.conf` (`configured_phases.py` L777-L787). Existing Macs get zram from `migrations/1789154627.sh`, fresh ones none | Present: ships `default/systemd/zram-generator.conf.d/90-omarchy.conf` on aarch64 (gap audit U5, triage #490) | 14 (gap audit U5, triage #490) | Existing and fresh Macs disagree today. When 14 ships the vendor drop-in, retire the `/etc/systemd/zram-generator.conf.d/90-omarchy.conf` copy that `1789154627.sh` writes, since it shadows the `/usr/lib` drop-in of the same name. |
| [#389](https://github.com/omacom/omarchy-mac/pull/389) (logging hunk) | When a setup leaf fails, print its path, exit status and log location on stderr (`install/helpers/logging.sh`) | Absent (same as upstream) | Absent (`install/helpers/logging.sh` L73 logs only) | **M3** | Generic. Useful for 41's deferred steps. The Snapper half of #389 is superseded (below). |

## Present on quattro-upstream

| PR | Change | Evidence on `qu` |
| --- | --- | --- |
| [#184](https://github.com/omacom/omarchy-mac/pull/184) | Apple trackpad detection and HID boot race | `bin/omarchy-hw-touchpad`, `install/hardware/apple/fix-asahi-hid-race.sh` (gap audit D5, D9) |
| [#186](https://github.com/omacom/omarchy-mac/pull/186), [#221](https://github.com/omacom/omarchy-mac/pull/221) | Protected audio stack, with `rtkit` | `621ab2ad5`, `install/hardware/apple/audio.sh` L33-L54 (A1) |
| [#196](https://github.com/omacom/omarchy-mac/pull/196) | Persist the XKB layout and variant chosen in the owner wizard so Hyprland uses it | Different mechanism: `bin/omarchy-provision-owner` `apply_keyboard` runs `systemd-firstboot --keymap`, which has also written `XKBLAYOUT`/`XKBVARIANT` since systemd `8a008fa79` (2025-02); `default/hypr/input.lua` L29-L32 reads them. Check a non-US layout on the M2 Max in 25. |
| [#198](https://github.com/omacom/omarchy-mac/pull/198) | Mac keybinding and input manual pages | `manual/03`, `07`, `12`, `34`. Reworked: the direct `Super + Alt + F12` recording chord was dropped for the `Super + Ctrl + C` Capture menu. |
| [#210](https://github.com/omacom/omarchy-mac/pull/210) | Capture chords on the Apple top row without Fn | `b86e2aff9`, `default/hypr/bindings/utilities.lua` L45-L56, gated on the detector |
| [#213](https://github.com/omacom/omarchy-mac/pull/213) | Seed SDDM's last user on a first install | `ed5d0534a` |
| [#215](https://github.com/omacom/omarchy-mac/pull/215) | F1/F2 names for the brightness keys in the keybindings menu | `c1673ae67`, `bin/omarchy-menu-keybindings` L65-L67 |
| [#219](https://github.com/omacom/omarchy-mac/pull/219) | Prefer `apple-panel-bl` over the Touch Bar backlight | `bin/omarchy-hw-display` (also skips the Touch Bar nodes) |
| [#223](https://github.com/omacom/omarchy-mac/pull/223), [#224](https://github.com/omacom/omarchy-mac/pull/224) | Battery percentage rounding; cycle count from the battery's own sysfs | `5c47e8c11`; `bin/omarchy-battery-status` L135-L136, `69a72dce9` |
| [#229](https://github.com/omacom/omarchy-mac/pull/229), [#259](https://github.com/omacom/omarchy-mac/pull/259) | zram-generator on existing Macs, once per machine | `a31f88dd6`, `4d767bc68` (`migrations/1789154627.sh`). #229's DNS hunk is covered by `inst2` (`finalized_phases.py` L476-L485 links `stub-resolv.conf`); its keyring hunk is legacy `install.sh`. |
| [#387](https://github.com/omacom/omarchy-mac/pull/387) | Supply a zram default when nothing configures it, so the migration stops failing with `Device zram0 not found` | Reworked in `4d767bc68` (`migrations/1789154627.sh` L13-L35). Differences for 14: `qu` checks three paths with `-f` (#387 checks every generator directory), so a `/dev/null` symlink mask counts as unconfigured and gets the default; and `qu` ignores a failed start (`|| true`) where #387 leaves the migration pending. |
| [#234](https://github.com/omacom/omarchy-mac/pull/234) | UTF-8 locale when `LANG` is C | `b95df7fcc` |
| [#236](https://github.com/omacom/omarchy-mac/pull/236) | Timezone prompt only while still on UTC | `0967cc510` |
| [#242](https://github.com/omacom/omarchy-mac/pull/242) | Keep first-run retryable when user finalization fails | `94f514cd2` |
| [#243](https://github.com/omacom/omarchy-mac/pull/243) | Obsidian preinstall on aarch64 | `7de9637bd`, `1c38e8f33` (AppImage build; the packaged `obsidian` is gap audit O4, 14) |
| [#249](https://github.com/omacom/omarchy-mac/pull/249) | Apple SMC lid detection | `30e876969`, `bin/omarchy-hw-laptop` L25 |
| [#251](https://github.com/omacom/omarchy-mac/pull/251) | Steam bootstrap and "Waiting for network" on Apple Silicon | `b5463029e`, `e95304671`; the launcher and network patch ship in ompkgs `omarchy-steam-fex` (Q8, triage #511) |
| [#255](https://github.com/omacom/omarchy-mac/pull/255) | Wi-Fi recovery after resume | `packages/omarchy-mac/bin/omarchy-wifi-resume-fix` and unit (Q2; BCM4388 is triage #465, 38) |
| [#258](https://github.com/omacom/omarchy-mac/pull/258) | Retire `alarm` from wheel on existing installs | `e690e5ee4`, `migrations/1789158179.sh` |
| [#298](https://github.com/omacom/omarchy-mac/pull/298) | Apple Video Decoder stack | `9a16eabaa` (Q5; the browser green-frame bug is triage #418, 40) |
| [#303](https://github.com/omacom/omarchy-mac/pull/303) | Keyboard backlight from the ambient light sensor | `8abd0da30` (Q4; unit shipping is #432 above) |
| [#377](https://github.com/omacom/omarchy-mac/pull/377) | 4.0.3rc1 stabilization bundle | Electron and 1Password software GL: `e6f2e6ad6`, `b031448e6`, `49051f940` (Q7). Mic array mapping, default-sink restore, speakersafetyd retry: `packages/omarchy-mac` mapper, `audio.sh` L50-L54 (Q1). wf-recorder, 48 kHz AAC, webcam overlay focus and renderer: `780d82acd`, `57d1c95a1`. Timezone argv: `0967cc510`. Snapper hardening: `682d5ee49`, `1c38e8f33`, `migrations/1789148088.sh`. Lid close (#373): `utilities.lua` L37-L40. Passwordless sudo fail-closed (#376): upstream omacom/omarchy#9387. The rest is superseded (#360, boot-to-ESP, CI records; below). |
| [#403](https://github.com/omacom/omarchy-mac/pull/403) | Mic mapper wakes on PipeWire events instead of polling | `packages/omarchy-mac/bin/omarchy-audio-asahi-mic-map` `Subscription` (`pactl subscribe`, L285-L300) |
| [#435](https://github.com/omacom/omarchy-mac/pull/435) `6e463e95a`, `23e1e7cbd` | Keep the nested Snapper store across a Mac root restore | `bin/omarchy-system-snapshot-restore` L158-L180 moves the nested store (simpler: no receipt or undo helper). The converged restore path is 36. |

## Superseded by the convergence design

Spec sections are under Implementation Decisions unless named otherwise.

| PR | Change | Spec section | Notes |
| --- | --- | --- | --- |
| [#188](https://github.com/omacom/omarchy-mac/pull/188), [#192](https://github.com/omacom/omarchy-mac/pull/192), [#201](https://github.com/omacom/omarchy-mac/pull/201), [#205](https://github.com/omacom/omarchy-mac/pull/205), [#228](https://github.com/omacom/omarchy-mac/pull/228) | README, guided-installer URLs and org home; migration `1787417162` repoints the checkout at GitHub | Repositories and ownership (Mac docs in omarchy-mac, 58) | *Legacy*: 44's checkout conversion must accept Codeberg and GitHub origins. |
| [#193](https://github.com/omacom/omarchy-mac/pull/193), [#244](https://github.com/omacom/omarchy-mac/pull/244) | Guided installer (`bin/omarchy-mac-setup`): bootstrap admin handoff, resume config escaping | Installer and images (02, 21, 23) | *Legacy fix*. `qu` retires `alarm` from wheel (`e690e5ee4`). |
| [#204](https://github.com/omacom/omarchy-mac/pull/204), [#214](https://github.com/omacom/omarchy-mac/pull/214), [#225](https://github.com/omacom/omarchy-mac/pull/225), [#248](https://github.com/omacom/omarchy-mac/pull/248), [#250](https://github.com/omacom/omarchy-mac/pull/250) | 3.x to Quattro upgrade (`bin/omarchy-upgrade-to-quattro-mac`) | Migration ("Pre-Quattro legacy installs first pass through the existing Quattro upgrade path") | *Legacy fixes*; they stay on `quattro`. #214's `quickshell-git` guard is not needed on the converged repository: ompkgs builds it for aarch64. |
| [#207](https://github.com/omacom/omarchy-mac/pull/207) | Retire `omarchy-mac-lock-on-boot` autologin for SDDM (migration `1787514420`) | Upstream login already on `qu` | *Legacy*: Macs that skipped it still auto-login (triage #322); 44 retires it. |
| [#230](https://github.com/omacom/omarchy-mac/pull/230) | Shell-suite fixes for the GRUB-era `omarchy-mac-snapshot-restore` | Encryption, provisioning and boot lifecycle (GRUB-era snapshot tools are transition-only) | 36 (gap audit S5). |
| [#238](https://github.com/omacom/omarchy-mac/pull/238) | Install 1Password by default on aarch64; build the share picker at the user stage | Package set | Upstream makes 1Password an optional menu install; `qu` follows it (`49051f940`) and builds the picker per user (`0259fde82`). Signed source is O5 (14). |
| [#245](https://github.com/omacom/omarchy-mac/pull/245) | ARM mirror helper test paths | Platform isolation (package lists) | `qu` uses `default/pacman/aarch64/*`; 14. |
| [#247](https://github.com/omacom/omarchy-mac/pull/247), [#263](https://github.com/omacom/omarchy-mac/pull/263), [#358](https://github.com/omacom/omarchy-mac/pull/358) | `build-packages.sh`: isolated outputs, Mac-only pkgrel, keep the Apple mkinitcpio drop-ins in the aarch64 settings package | Package set (forked runtime/settings disappear; recipes in omarchy-pkgs, 08, 09); Platform isolation (composable HOOKS, 15, 16) | Build tooling is quattro-only. |
| [#332](https://github.com/omacom/omarchy-mac/pull/332), [#347](https://github.com/omacom/omarchy-mac/pull/347) | CI on every push and PR, ARM install VM, Landlock in the guest | Testing Decisions | 57 (#518) and 27 (#515). #347's repeat-install firewall hunk is generic (not Apple). |
| [#334](https://github.com/omacom/omarchy-mac/pull/334) | Let root run `omarchy-plymouth-set --refresh-default` | Platform isolation (mkinitcpio fragments, 16) | The root caller, `install/login/plymouth.sh`, is quattro-only. Mac initramfs Plymouth is gap audit E13 (16); image branding is 23. |
| [#345](https://github.com/omacom/omarchy-mac/pull/345), [#346](https://github.com/omacom/omarchy-mac/pull/346), #360 (in #377) | Selective official-edge Hyprland stack, preserved through install and update with `--needed` | Package set | aquamarine carry is 10; repository order is 14's open decision. If 14 chooses "update re-asserts repo-qualified overrides", keep #360's `--needed`. |
| [#354](https://github.com/omacom/omarchy-mac/pull/354) | `fix-arm-packages.sh` for installs stranded before the ARM package-sources policy | Migration (preflight) | *Legacy*: 44's preflight must recognise these machines. |
| [#385](https://github.com/omacom/omarchy-mac/pull/385) | MLX in the AI install menu | Out of Scope (MLX is a separate workstream) | Triage #425 has the carry notes. |
| [#389](https://github.com/omacom/omarchy-mac/pull/389) | Make `snapper` a hard dependency of the Mac `omarchy` package | Package set (`omarchy-mac-boot` owns the Limine lifecycle) | p65 `omarchy-mac-boot` depends on `limine-snapper-sync` (PKGBUILD L18), which brings `snapper`, once 04 adds the boot package to `install/omarchy-apple.packages` (gap audit must-fix 4). Until then nothing on `qu` installs `snapper` on a Mac (ompkgs `omarchy` has it only in `depends_x86_64`, L70-L75) and `install/config/snapper.sh` L20 fails with 127. The logging hunk is missing (above). |
| [#435](https://github.com/omacom/omarchy-mac/pull/435) (rest) | ARM channel lanes and isolated staged transactions, fork signing trust, pinned recipe inputs, zram repair for earlier migrators (`9dd3de50d`), factory reset and owner re-key rework, residual unlock keys | Package set; Migration; Encryption, provisioning and boot lifecycle | Trust and channels: 44. Factory reset and re-key: #503's mx port (gap audit E3, E5, E9; 32 to 34). `9dd3de50d`: `qu`'s own migration already supplies the default. *Legacy*: see findings 2 to 4. |
| [#444](https://github.com/omacom/omarchy-mac/pull/444), [#457](https://github.com/omacom/omarchy-mac/pull/457) | Finalized rc4 keyring; publication guard for `[omarchy-aarch64]` | Package set ("signed packages only", from omacom/omarchy-pkgs) | 30 for release tooling; 44 retires the keyring (finding 2). |
| [#464](https://github.com/omacom/omarchy-mac/pull/464) | E2E evidence collector for the volunteer checklist | Testing Decisions (hardware qualification) | Tied to the guided installer's files. 29 (#516) and 27 (#515); its redaction is worth offering to #516, as triage said for #466. |
| #377 parts | Boot-to-ESP guard for ISO layouts; CI and integration records | Installer and images; Testing Decisions | Boot-to-ESP belongs to the legacy encrypted flow (finding 1). |

## Codeberg-era merges and the direct push

| Merge | Change | Status |
| --- | --- | --- |
| #150, #152, #153 | Omarchy 4 for Apple Silicon and the fresh-install path | Distilled into `qu` through omacom/omarchy#9835 (`9cf789df6`, `4bc760378`) and the 2026-09-14/16 ports. Not re-audited line by line; the per-feature comparison is the gap audit's. |
| #155 | Encrypted one-command install: `omarchy-mac-setup`, `omarchy-system-btrfs-migrate`, `omarchy-system-boot-to-esp`, GRUB-era snapshot restore | Superseded (Installer and images; Encryption, provisioning and boot lifecycle). *Legacy*: it created the encrypted legacy cohort (finding 1). |
| #157 | macOS touchpad defaults | Present: `bfdb8e02b`, `374241ee2`, `0e10de8de` |
| #159 | Broadcom WPA quirk skipped on Apple Silicon | Present: `install/hardware/apple/fix-brcmfmac-supplicant.sh` (W1) |
| #160 | `[omarchy-aarch64]` served from the omarchy-mac org | Superseded (Package set); gap audit R1, R3 (14, 44) |
| #158, #161 | README install path, `quattro` as the default ref | Superseded (58; the installer app replaces the flow) |
| `739eb5a32` | aarch64 pacman configs, mirrorlist, dotnet unavailable | Superseded: `qu` `default/pacman/aarch64/*`; package lists are 14 |

## Not Apple Silicon

- Upstream syncs: #233, #308.
- Generic fixes, not on `qu` or upstream: #237 (Taildrop paths), #239 (launch-or-focus argument quoting), #347's repeat-install firewall hunk, and in #435 `bfb9c12c4` (network QR without a route) and `6b5e311d3` (`omarchy update -y` still prompts to reboot). They belong on omacom/omarchy.
- Generic, on `qu` through upstream: #241 (clock popup anchoring, `3e4774868`, omacom/omarchy#8942), #386 and #435 `1c3dc3feb` (Hermes).
- Tests, versions and CLI metadata: #209, #253, #357, #426.

## Legacy cohort findings (input to 42 to 45)

1. **Legacy Macs are often encrypted.** Since #155 (2026-08-21), `omarchy-mac-setup` encrypts by default. It converts the root to LUKS2 in place (`omarchy-system-btrfs-migrate --encrypt`, a user-chosen passphrase), boots it through busybox `encrypt` (`etc/mkinitcpio.conf.d/omarchy_hooks.conf`) with `cryptdevice=` on the GRUB line, and moves `/boot` onto the vfat ESP first (`omarchy-system-boot-to-esp`, leaving `/boot.old`). Ticket 45's "System remains unencrypted" and user story 27 assume unencrypted legacy machines. These Macs are the busybox case of gap audit B4 and B18, and the ESP-at-`/boot` case of B6. See M2.
2. **Fork signing trust.** rc4 (#435 `fea4693e8`, #444; migrations `1789316115`, `1789407944`) installs `omarchy-mac-keyring`, whose `pacman-key --populate` locally signs `FBD6874D423C418DDB6D143EECE19CDDE306DBD2` as a trusted packager key (`default/pacman/keyrings/omarchy-mac-trusted`), while `[omarchy-aarch64]` stays `SigLevel = Optional TrustAll`. 44 must remove the package and the key, as 43 removes mx's `C81AC3E2…` (gap audit R2), and handle rc5 if it ships (triage #436).
3. **Channel machinery.** ARM lanes and staged transactions (`install/helpers/arm-channel.sh`, `omarchy-channel-set`) and the selective-edge policy (`install/helpers/arm-package-sources.sh`) must be recognised and retired by 44's preflight.
4. **Root layout.** `quattro`'s factory reset can leave `@factory`, `@omarchy-old-factory-*`, `@old-*` and `@fresh` beside `@`, and can change the Btrfs default subvolume (`784bcb73a`). Its restore keeps a nested Snapper backend (`bin/omarchy-mac-snapper-backend`, migration `1789285718`). 42's backups and 45's Limine command line must read the real root subvolume, not assume `@`.
5. **Login and recovery leftovers.** Autologin from `omarchy-mac-lock-on-boot` (#207), installs stranded before the package-sources policy (#354), and checkouts pointing at Codeberg or GitHub (#188).

## Proposed new tickets

| ID | Proposed title | Tag | Covers |
| --- | --- | --- | --- |
| M1 | Apple Silicon battery charge limit | runtime | #497, plus triage #356 (read thresholds from sysfs before UPower, since `macsmc-battery` never signals a change). Decide between an `omarchy-mac` command gated on the detector and joining upstream's charge-limit work (omacom/omarchy#11792, #13205). Keep #497's driver semantics (80/75, 100/100) and check whether the limit survives reboot and shutdown on the M1 Pro and M2 Max. |
| M2 | Encrypted legacy omarchy-mac installs through migration | boot | Finding 1. Amend 45 (and 42's and 44's preflight): keep an encrypted legacy root encrypted, convert busybox `encrypt` + `cryptdevice=` + `/boot` on the ESP to the Limine layout with the LUKS unlock verified before the active loader changes, or refuse in preflight with a documented path. Needs a legacy encrypted fixture built with `omarchy-mac-setup --encrypt`. |
| M3 | Send quattro's generic Apple-motivated fixes to omacom/omarchy | generic | #483 (Voxtype Vulkan backend check), #474 (Brave Widevine link; check Brave Origin), #389's setup-failure message. All are no-ops or harmless off Apple Silicon. |
