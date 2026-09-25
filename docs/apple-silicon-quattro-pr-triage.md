# Apple Silicon fixes open against omarchy-mac `quattro`: triage

Ticket 59 of the Apple Silicon convergence spec (`docs/apple-silicon-convergence.md`, [#512](https://github.com/omacom/omarchy-mac/pull/512)). Every open omacom/omarchy-mac PR whose base is `quattro` and that touches Apple Silicon behaviour, with a recommendation: retarget to `quattro-upstream`, already covered, or drop. The owner acts on the PRs; nothing here was commented on, labelled, retargeted or closed.

Triaged 2026-09-25 (Brisbane) from source only: nothing was built or run on a Mac. 82 PRs were open against `quattro`; 48 touch Apple Silicon behaviour and are triaged below, and the other 34 are listed at the end.

## Sources

| Short | Repository and ref | Commit |
| --- | --- | --- |
| `quattro` | omacom/omarchy-mac `quattro` (base of every PR here) | `e77295a9f8ab` |
| `qu` | omacom/omarchy-mac `quattro-upstream` | `b4a79d83d114` |
| `503` | omacom/omarchy-mac draft [#503](https://github.com/omacom/omarchy-mac/pull/503) `integrate/quattro-encryption-limine` | `0d4070aeac3f` |
| `mx` | maralcbr/omarchy-mx-mac `main` | `8e70a5cdcc82` |

Ticket numbers are from the convergence ticket index. Row IDs such as E12 or Q4 are from the gap audit ([#513](https://github.com/omacom/omarchy-mac/pull/513), `docs/apple-silicon-gap-audit.md`).

## Recommendations

- **Retarget**: still needed on the converged path and not on `qu` yet. The cell names the owning ticket and where the change lands. Most need rework, because `qu` moved Mac-only code into `packages/omarchy-mac/` and gates on `omarchy-hw-apple-silicon` (soon `omarchy-hw-platform`, #514) instead of `uname -m`.
- **Covered**: `qu` or #503 already has equivalent behaviour. The cell is the pointer for a closing comment.
- **Drop**: nothing to port. The reason is given. Rows marked *legacy fix* repair a live bug in the `quattro` install or upgrade path that legacy users still run before migration (the spec sends pre-Quattro installs through that path first). Whether they merge on `quattro` is the `quattro` maintainer's call; they are not for `qu`.

## Summary

- 18 retarget, 5 covered, 25 drop (10 of them *legacy fixes*).
- Bugs confirmed present on `qu` today: Wi-Fi resume excludes BCM4388 (#465), no Bluetooth resume recovery (#498), bare `rfkill` block wedges `hci_bcm4377` (#380), 96 kHz recordings trip `speakersafetyd` (#502), browsers send video to AVD and render green (#418), DDC probing on connectors without a `ddc` node (#491), the ALS keyboard loop stays paused after an off leftover (#486), `vulkan-asahi` lost in the Mesa 26.2 split on the update path (#489), and an unregistered Snapper root left for manual repair (#450).
- Latent on `qu`: the mic user-bus fallback (#462), the keyboard ALS unit enabled under `set -e` but not shipped by omacom's `omarchy-settings` recipe (#367), UPower-first charge thresholds (#356).
- #434 is an Intel (x86_64) MacBookPro12,1 fix, not Apple Silicon.
- Bluetooth (#498, #380) has no exact owner; the nearest is 38, which the owner can widen or split. Touch Bar, Apple menu labels and M1 Air bindings (#363, #307, #390) are outside the spec and have no ticket. One follow-up is suggested: a sweep of Apple work already merged on `quattro` (see the notes).

## Wi-Fi and Bluetooth

| PR | Author | Change | `qu` / `503` | `mx` | Recommendation |
| --- | --- | --- | --- | --- | --- |
| [#465](https://github.com/omacom/omarchy-mac/pull/465) | ansonboby | Add BCM4388 (`14e4:4434`, M2 Pro/Max) to Wi-Fi resume recovery | Absent; bug present. `packages/omarchy-mac/lib/wifi-supported` excludes 4434 on purpose and `packages/omarchy-mac/test/{setup,wifi}-test.sh` assert it | None (Q2 is `qu`-only) | **Retarget → 38.** Add 4434 to `lib/wifi-supported`, flip the two package tests, replace the quattro migration with one that runs `omarchy-setup-mac --system`. The exclusion came from a six-minute s2idle test on an M2 Max; the PR reports a lid-close wedge on an M2 Pro, so 38's M2 Max check should cover lid close. |
| [#498](https://github.com/omacom/omarchy-mac/pull/498) | n0mahd | Rebind `hci_bcm4377` after resume when HCI tx timeouts follow the last suspend (BCM4378/4387) | Absent; bug present (AsahiLinux/linux#604 open) | None | **Retarget → 38 (nearest; no Bluetooth ticket).** Build it in `packages/omarchy-mac` like the Wi-Fi fix: bin, vendor unit, a `lib/bluetooth-supported` gate on the detector, enabled by `omarchy-mac-setup-system`. The `/etc` heredoc unit, `all.sh` hook and migration go. |
| [#380](https://github.com/omacom/omarchy-mac/pull/380) | JJRPF | Power adapters off through BlueZ before `rfkill block` so `hci_bcm4377` doesn't wedge | Absent; bug present. `bin/omarchy-bluetooth-power` is identical on `quattro`, `qu` and upstream | None | **Retarget (generic; no ticket, nearest 38).** Applies as is. Better opened on omacom/omarchy so `qu` inherits it; overlaps upstream omacom/omarchy#12753 (scope the rfkill block to HCI adapters). |
| [#434](https://github.com/omacom/omarchy-mac/pull/434) | avillagran | Install a `linux-bcm43602` kernel on Intel MacBookPro12,1 for S3 Wi-Fi | Absent (x86 only) | None | **Drop.** Not Apple Silicon. Intel Mac work belongs upstream: omacom/omarchy#10332, #12688, #12691 and omacom/omarchy-pkgs#422 (the kernel, still open). |

## Audio

| PR | Author | Change | `qu` / `503` | `mx` | Recommendation |
| --- | --- | --- | --- | --- | --- |
| [#462](https://github.com/omacom/omarchy-mac/pull/462) | z23 | Call `systemctl --user` only when `XDG_RUNTIME_DIR` is set and has a bus | Latent: `packages/omarchy-mac/bin/omarchy-mac-setup-user:44` keeps the `${XDG_RUNTIME_DIR:-/run/user/$UID}/bus` fallback under `set -euo pipefail` | None | **Retarget → 37.** One-line guard in `omarchy-mac-setup-user`, test in `packages/omarchy-mac/test/setup-test.sh`. |
| [#478](https://github.com/omacom/omarchy-mac/pull/478) (draft) | e-jung | J456 iMac: filter-chain mic on the raw AOP channel when there is no Asahi DSP source | Absent: `omarchy-audio-asahi-mic-map` stops with "No Asahi DSP microphone" | None | **Retarget → 37.** Rebase onto `packages/omarchy-mac/bin/omarchy-audio-asahi-mic-map` (diverged: `restore_output`, detector gate); conf under `packages/omarchy-mac/share/`. Stays draft until the hardware checks are done. |
| [#502](https://github.com/omacom/omarchy-mac/pull/502) | ijt | Pin the loudnorm pass at 48 kHz so recordings aren't 96 kHz AAC (which panics `speakersafetyd`) | Absent; bug present: `bin/omarchy-capture-screenrecording:404` has no `-ar` | None | **Retarget → 37.** One-line carry next to `qu`'s existing `-R 48000`; drop it when upstream omacom/omarchy#11092 (open) merges. |

## Video decode

| PR | Author | Change | `qu` / `503` | `mx` | Recommendation |
| --- | --- | --- | --- | --- | --- |
| [#418](https://github.com/omacom/omarchy-mac/pull/418) | duketopceo | `--disable-features=AcceleratedVideoDecoder` for Chromium-family browsers, merged into existing `*-flags.conf` by migration, because AVD renders green frames | Absent; bug present: `qu` installs the AVD stack (`install/hardware/apple/video-decode.sh`) and `config/chromium-flags.conf` has no disable flag | None (no hardware decode, so no bug) | **Retarget → 40, with rework.** As written it edits the generic flags file with an ungated migration, which would turn off browser decode on x86 and Snapdragon too. Apply it from the Apple video-decode leaf or `omarchy-mac` setup, gated on the detector. |

## Display, input and Touch Bar

| PR | Author | Change | `qu` / `503` | `mx` | Recommendation |
| --- | --- | --- | --- | --- | --- |
| [#491](https://github.com/omacom/omarchy-mac/pull/491) | nickdumitru | Skip DDC when the connector has no `ddc` node (apple-drm), fail closed, session-long negative cache | Absent; bug present: `bin/omarchy-brightness-display` `use_ddc_display` only checks "not internal" | None (same code) | **Retarget → 39.** Applies unchanged. Before it goes upstream, check x86 MST/DisplayLink connectors without a `ddc` node; limiting the check to apple-drm is the safe variant. |
| [#486](https://github.com/omacom/omarchy-mac/pull/486) | oliverlukschander | ALS keyboard loop treats an LED at ≤2% as off, not a manual override, and resumes | Absent; bug present: `bin/omarchy-brightness-keyboard-auto` pauses on any LED change | None (Q4 is `qu`-only) | **Retarget → 39, with rework.** As written it also undoes a deliberate off: `bin/omarchy-brightness-keyboard` steps down to 0, which the PR treats as a leftover and relights in a dark room. Tell a manual off apart from lock blank and restore (for example a marker written by the manual command). The header and manual hunks conflict with `qu`'s wording. Land before #340. |
| [#340](https://github.com/omacom/omarchy-mac/pull/340) | DataKnox | Keyboard backlight off on idle, thresholds in `~/.config/omarchy/keyboard-backlight.conf` | Absent | None | **Retarget → 39 (optional feature on Q4).** Rebase after #486; both rewrite the `tick()` pause path. |
| [#463](https://github.com/omacom/omarchy-mac/pull/463) | z23 | libinput quirk sized from the MTP pad for palm rejection | Absent (only tap-to-click off and natural scroll) | None | **Retarget → 39, with rework.** Ship from `packages/omarchy-mac`, gated on the detector. As written it has no effect: libinput reads `.quirks` from its data directory and only `local-overrides.quirks` from `/etc/libinput`, so `/etc/libinput/omarchy-apple-mtp.quirks` is ignored. Verify with `libinput quirks list`. |
| [#390](https://github.com/omacom/omarchy-mac/pull/390) | kasimali59 | (a) M1 Air top-row bindings and Command/Option labels; (b) stop ARM updates reinstalling pinned Hyprland | (a) absent. (b) n/a: `qu` uses upstream's `omarchy-update-system-pkgs` | None | **Retarget (a) only; no ticket.** Gate on the detector; depends on the function-key policy in 56; agree one label policy with #307; `XF86Search` also claimed by #363. Drop (b): quattro ARM-channel machinery. |
| [#307](https://github.com/omacom/omarchy-mac/pull/307) | mantisdotdev | ⌘ ⌥ ⌃ ⇧ in the keybinding, tmux and Herdr menus | Absent | None | **Retarget; no ticket (Mac polish).** Ungated as written; gate like `qu`'s Apple F1/F2 rename in `bin/omarchy-menu-keybindings`. |
| [#363](https://github.com/omacom/omarchy-mac/pull/363) | austindixson | tiny-dfr with an Omarchy Touch Bar layer, F13/F14/Search binds | Absent (only the T2 tiny-dfr removal) | None | **Retarget; no ticket (Touch Bar is outside the spec), low priority.** `tiny-dfr` as an `omarchy-mac` dependency, layout written by `omarchy-mac-setup-system`, binds gated like b86e2aff9. |
| [#337](https://github.com/omacom/omarchy-mac/pull/337) | DataKnox | Touch Bar "Now Playing" app over raw DRM | Absent | None | **Drop.** Optional app, not a gap; its `%wheel` NOPASSWD helper that changes DRM node ownership needs its own security review; depends on #363. Can come back as an `omarchy-mac` add-on. |
| [#289](https://github.com/omacom/omarchy-mac/pull/289) | haripako | `omarchy debug dp-altmode`: explains that USB-C DP does nothing on M1 | Absent | Supersedes it: Aurora drives USB-C/USB4 displays | **Drop.** The diagnosis is about the Asahi kernel lane; the spec is Aurora-only, chosen because USB4 and external displays work. It would tell Aurora users working hardware is unsupported. |
| [#406](https://github.com/omacom/omarchy-mac/pull/406) | avillagran | Out-of-tree Asahi kernel patch for HDMI reconnect, with PKGBUILD and CI | n/a (no kernel builds in omarchy-mac) | None | **Drop as filed.** Targets the Asahi kernel. If the bug reproduces on Aurora, the fix belongs in aurora-silicon/linux or a `linux-aurora` patch under 06; Aurora's DCP code has diverged, so it needs a real port. |

## Platform detection, packages and runtime

| PR | Author | Change | `qu` / `503` | `mx` | Recommendation |
| --- | --- | --- | --- | --- | --- |
| [#481](https://github.com/omacom/omarchy-mac/pull/481) | lloyd094 | `grep -a` on `/proc/device-tree/compatible` at eight Apple probes | Covered: every probe goes through `bin/omarchy-hw-apple-silicon` (`grep -aq 'apple,'`); Widevine backfill is `migrations/1789155585.sh` | Equivalent (`bin/omarchy-hw-apple-silicon`) | **Covered → 13.** Pointer: `qu` `bin/omarchy-hw-apple-silicon`, and #514's `omarchy-hw-platform`. Stacked on #480. |
| [#482](https://github.com/omacom/omarchy-mac/pull/482) | lloyd094 | Codex usage collector fails fast with stderr instead of timing out | Absent (generic, same on upstream) | Same code | **Drop.** Carries #480 and #481; its own commit is generic and belongs on omacom/omarchy. |
| [#331](https://github.com/omacom/omarchy-mac/pull/331) | malik-na | Architecture detectors, split `default/pacman/aarch64/`, aarch64 install dispatch | Covered: `default/pacman/aarch64/*`, `install/helpers/pacman.sh`, `omarchy-hw-apple-silicon` | Partial | **Covered → 13.** Pointer: `qu`'s pacman split and detector, plus #514 (detector and architecture-gate lint). The rest is legacy machinery. Contained in #353. |
| [#353](https://github.com/omacom/omarchy-mac/pull/353) (draft) | malik-na | #331 plus recipes pinned to omarchy-pkgs with a Mac profile patch, lid and reset guards | Partial: detection, lid routing and laptop detection covered; reset path in 503 | Partial | **Drop.** Detection is 13; recipe pinning and the profile patch are replaced by commit-pinned `omarchy-mac` recipes (08) and runtime profiles (14); the reset guard by 503 and 34. |
| [#349](https://github.com/omacom/omarchy-mac/pull/349) (draft) | scottjones | Electron/1Password software GL when there is no render node | Covered: e6f2e6ad6, b031448e6 (same author) | None (Q7) | **Covered.** Pointer: `qu` e6f2e6ad6 and b031448e6. |
| [#326](https://github.com/omacom/omarchy-mac/pull/326) | CptPanko | `omarchy-hw-apple-silicon-generation` (m1…m4 from `apple,tNNNN`) | Absent | Partial (M3 regex only, dropped as K7) | **Drop.** Only serves M3/M4 policy, which is out of scope; the platform detector deliberately stops at `apple-silicon`. |
| [#343](https://github.com/omacom/omarchy-mac/pull/343) | staccDOTsol | M3 support: SoC detector, software rendering, Asahi installer path, WIP kernel | Absent (no-GPU software cursor already on `qu`) | Partial (M3 keeps linux-asahi, K7) | **Drop.** M3 and the Asahi kernel lane are out of scope. The every-Mac software cursor is 39 (D1). |
| [#489](https://github.com/omacom/omarchy-mac/pull/489) | nickdumitru | Name `vulkan-asahi` in updates and backfill it after the Mesa 26.2 split | Partial; bug present: fresh install gated correctly (`install/hardware/vulkan.sh`), but no update path or migration, and `migrations/1784401744.sh` and `bin/omarchy-upgrade-to-quattro` gate on `lspci … Apple`, which never matches | Partial (upgrade only) | **Retarget → 14, with rework.** The fix must resolve inside the update's own `-Syu`, because migrations run after it (`bin/omarchy-update`) and a dependency failure stops the update first. Make `vulkan-asahi` an `omarchy-mac` dependency rather than patching upstream's `omarchy-update-system-pkgs`, add it to the Apple package list for fresh installs, keep a detector-gated backfill for Macs that already lost Vulkan, and fix the two `lspci` gates. |
| [#490](https://github.com/omacom/omarchy-mac/pull/490) | nickdumitru | Write zram `vm.*` tunings to a separate `/etc/sysctl.d` file on aarch64 | n/a: the zram helpers are quattro-only; on `qu` the aarch64 settings recipe strips the zram drop-in and tunings (U5) | Equivalent (ships both on aarch64) | **Drop → 14.** Works around package-time stripping with an unowned `/etc` file; 14 replaces the stripping with runtime profile selection. Keep its values as the reference. |
| [#367](https://github.com/omacom/omarchy-mac/pull/367) | megabyte0x | Stop the first-run login loop when a shipped user unit is missing | Latent: `install/user/first-run/enable-user-units.sh` enables `omarchy-brightness-keyboard-auto.service` under `set -e`, and omacom's `omarchy-settings` recipe doesn't ship it | None | **Retarget → 14 (the `enable-user-units.sh` hunk only).** The packaging and repair hunks are already on `quattro` (#432, e77295a9f). 14 must also make the settings build ship the full `default/systemd/user` set. |
| [#378](https://github.com/omacom/omarchy-mac/pull/378) | DataKnox | Add the keyboard ALS unit to the aarch64 settings package via `build-packages.sh` | n/a (`build-packages.sh` is quattro-only) | None | **Drop → 14.** Already done on `quattro` by #432; the converged fix is 14 (see #367). |
| [#450](https://github.com/omacom/omarchy-mac/pull/450) | luneth90 | Register an existing, complete Snapper root config in `/etc/conf.d/snapper`; retry installing `snapper` in the repair migration | Partial; bug present: `install/config/snapper.sh` returns 3 for a registered-nowhere root config and `migrations/1789148088.sh` leaves it for manual repair | Equivalent: `install/config/snapper.sh:32` writes `SNAPPER_CONFIGS="root"` | **Retarget → 36 (the registration hunk), plus a new migration.** Generic leaf shared with upstream. Macs that already ran `1789148088.sh` got status 3 turned into success and are stamped, so they need a new detector-gated migration to rerun the leaf. The `omarchy-pkg-add snapper` self-heal answers quattro's package lag; drop it. |
| [#356](https://github.com/omacom/omarchy-mac/pull/356) | jastincheis | Read charge thresholds from sysfs before UPower (`macsmc-battery` never signals a threshold change) | Latent: `bin/omarchy-battery-status` reads UPower first; `qu` has no charge-limit setter yet | None | **Retarget; no ticket (generic, P1), low priority.** Swap the read order in `qu`'s block; also valid on `quattro`, which has the setter (#497). |
| [#393](https://github.com/omacom/omarchy-mac/pull/393) | malik-na | Low-battery guard: 60 s countdown at 5%, close windows, power off; remapped charge display | Absent | None | **Drop from omarchy-mac.** Platform-neutral laptop feature (`macsmc-battery` is only a default argument); propose it to omacom/omarchy, as its `cherry-pick-later` label suggests. |
| [#511](https://github.com/omacom/omarchy-mac/pull/511) | malik-na | Hand `omarchy-launch-steam` to the `omarchy-steam-fex` package | Covered: b5463029e, `migrations/1789522888.sh`; `qu` never shipped its own launcher | None | **Covered (Q8, 14).** Pointer: `qu` b5463029e. Two extras `qu` lacks (install-failure check, `omarchy launch steam` proxy) can come over as a small follow-up. |
| [#425](https://github.com/omacom/omarchy-mac/pull/425) | joshuaswarren | MLX installed state keyed on `mlx-omarchy-info`, v0.7.3 pin, wider chip list | n/a: no MLX commands on `qu` | None | **Drop (legacy fix).** MLX is a separate workstream outside the spec. Approved and quattro-only; when MLX reaches `qu`, carry the installed-state key and chip list, gated on the detector. |

## Installation, setup and channels

| PR | Author | Change | `qu` / `503` | `mx` | Recommendation |
| --- | --- | --- | --- | --- | --- |
| [#500](https://github.com/omacom/omarchy-mac/pull/500) | malik-na | Ask for the keyboard layout first in the guided Mac installer | Covered: `bin/omarchy-provision-owner` `run_setup` runs `keyboard_form` before `user_form` (and before the 503 re-key) | Equivalent | **Covered.** Pointer: `qu` `bin/omarchy-provision-owner` `run_setup`. The layout at the initramfs passphrase prompt is E12 (16). |
| [#488](https://github.com/omacom/omarchy-mac/pull/488) | nickdumitru | Piped `omarchy-mac-setup --help` prints its own help | n/a | None | **Drop (legacy fix).** Guided installer only; replaced by the installer app (02, 21, 23) and first-boot provisioning (32). |
| [#487](https://github.com/omacom/omarchy-mac/pull/487) | nickdumitru | `--status` stops reporting stale encryption intent after install | n/a | None | **Drop (legacy fix).** Duplicate of #480 (both fix #473); #487 is the smaller one. |
| [#480](https://github.com/omacom/omarchy-mac/pull/480) | lloyd094 | Same as #487, reporting "unknown" when the answer file is gone | n/a | None | **Drop (legacy fix).** Duplicate of #487. #481 and #482 carry this commit. |
| [#452](https://github.com/omacom/omarchy-mac/pull/452) | resolvicomai | Keep `FONT=` lines when the guided installer applies a keymap | n/a: nothing on `qu` or 503 writes `FONT=` to `vconsole.conf` | None | **Drop (legacy fix).** The bug needs the legacy installer's persisted console font. |
| [#466](https://github.com/omacom/omarchy-mac/pull/466) | skuthus | E2E evidence collector that rides `omarchy-mac-setup` | Absent; the converged equivalents are #515 (27) and #516 (29) | Partial (`omarchy-debug-apple`, validation runbook) | **Drop → 29.** Tied to the legacy flow's files and service. Its data redaction and "version is not first login" verdict are worth offering to #516. |
| [#442](https://github.com/omacom/omarchy-mac/pull/442) | 1A7432 | README entry for the Asahi Alarm installer's Bad CRC-32 failure | n/a | None | **Drop.** The converged installer doesn't use the Asahi Alarm installer or its mutable ZIPs, so 58 shouldn't take it. Fine on `quattro`'s README while that flow is documented there. |
| [#391](https://github.com/omacom/omarchy-mac/pull/391) (draft) | scottjones | Install published ARM core packages instead of local `build-packages.sh` builds | n/a | Equivalent (signed published pair) | **Drop.** Superseded by signed, pinned candidates and images (22, 23); `[omarchy-aarch64]` is being retired (R3). |
| [#379](https://github.com/omacom/omarchy-mac/pull/379) | scottjones | Separate stable/rc/edge endpoints for `[omarchy-aarch64]` with manifest-checked switching | n/a: `qu` uses upstream channels; its `install/hardware/apple/pacman.sh` pins `[omarchy-aarch64]` to edge | Partial (own lanes, dropped as K5) | **Drop.** The spec publishes only through omacom/omarchy-pkgs with upstream channels and scoped aarch64 promotion (14, 52); the edge pin goes when R3 removes the repository. |
| [#436](https://github.com/omacom/omarchy-mac/pull/436) | malik-na | 4.0.3rc5: `[omarchy-aarch64]` requires signatures after the rc4 keyring bootstrap | Absent: `qu` still adds `[omarchy-aarch64]` with `SigLevel = Optional TrustAll` (R1) | Equivalent (retires the repo for signed `[omarchy]`) | **Drop (legacy fix).** The spec retires `[omarchy-aarch64]` instead of signing it, with official trust bootstrapped by 44; `qu`'s TrustAll gap is 14, 22, 52. Retargeting would port the wrong key. If rc5 ships on `quattro`, 44 must handle both the TrustAll and the strict state. |

## Legacy upgrade path

`bin/omarchy-upgrade-to-quattro-mac` exists only on `quattro`. `qu`'s `omarchy-upgrade-to-quattro` is upstream's x86 script, and legacy Macs reach `qu` through the migration engine (42, 44, 45), which starts after they have upgraded to Quattro.

| PR | Author | Change | `qu` / `503` | `mx` | Recommendation |
| --- | --- | --- | --- | --- | --- |
| [#322](https://github.com/omacom/omarchy-mac/pull/322) | CptPanko | Move login from seamless login to SDDM during the Mac upgrade, with an apple-drm wait (greeter crash loop, #314) | n/a; the greeter's apple-drm wait is also missing on `qu` (D7) | Equivalent (seamless-login retirement, `sddm.service.d/10-wait-for-drm.conf`) | **Drop (legacy fix).** Port D7 to `qu` under 39 from mx's drop-in, not from this helper. 44 must retire seamless login on Macs upgraded before this fix. |
| [#321](https://github.com/omacom/omarchy-mac/pull/321) | CptPanko | Make config upgrades resumable (one durable backup, staged hypr config) | n/a | Partial (different design) | **Drop (legacy fix).** A retry today can lose config that the later migration can't restore. |
| [#319](https://github.com/omacom/omarchy-mac/pull/319) | CptPanko | Manifest of fixed system paths the checkout upgrade wires | n/a (package-based installs) | Not needed | **Drop (legacy fix, after review).** Superseded by 44's checkout-to-package conversion; the reviewer's blocker (untested hardcoded manifest digest) still stands. |
| [#262](https://github.com/omacom/omarchy-mac/pull/262) | JeanBaeez | Trust the Asahi Alarm key before `pacman -Sy` in the Mac upgrade | n/a: image installs preflight `asahi-alarm-keyring` | None | **Drop (legacy fix).** Without it affected 3.x Macs can't reach Quattro, or the migration after it. Needs a rebase onto `ensure_arm_package_repo`. |

## Not Apple-specific (not triaged)

These open `quattro` PRs change generic desktop behaviour, gate aarch64 binary availability (a legitimate architecture check under the spec, shared with Snapdragon), or automate the repository. None is an Apple Silicon fix. Generic fixes that still apply belong on omacom/omarchy.

- Generic desktop: #461, #460, #459, #458, #454, #448, #438, #421, #420, #419, #417, #415, #414, #411, #410, #409, #383, #339, #330, #325, #324, #320, #318, #305
- aarch64 app availability: #424 (Cursor AppImage), #416 (Prism Launcher), #413 and #329 (Dropbox), #412 and #327 (Spotify), #328 (VS Code), #294 (1Password)
- Repository automation: #510, #467

## Notes for the owner

- Stacks and duplicates: #481 and #482 both contain #480's commit; #480 and #487 fix the same issue; #353 contains all of #331.
- Order: #486 before #340 (same `tick()` path); #390, #307 and #363 need one Apple label and binding policy (and #390 waits on 56).
- Most retargets need rework into `packages/omarchy-mac` and a detector gate, so a retarget is a request to rebase, not a base-branch switch.
- Out of scope here: Apple work already merged on `quattro` after `qu` was distilled. Neither this triage nor the gap audit (which compares `mx`) covers it. For example #497 (Apple Silicon charge-limit command, merged 2026-09-23) is not on `qu`; #496 and #432 merged the same day. A short `quattro` → `qu` merged-PR sweep would close that gap.
