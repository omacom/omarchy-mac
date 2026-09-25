# Spec: Apple Silicon convergence on quattro-upstream

## Problem Statement

Omarchy on Apple Silicon exists as two diverging efforts. The omarchy-mx-mac fork has a qualified macOS installer (2.0.10), in-place LUKS encryption with owner provisioning, a Limine boot chain behind m1n1 and U-Boot, the Aurora kernel lanes, signed package snapshots and a VM/hardware acceptance harness. It is built on upstream v4.0.4 and edits many core Omarchy files inline, so it cannot merge upstream. The shared collaboration branch, omarchy-mac `quattro-upstream`, sits on Quattro with a much smaller upstream diff and a package-based add-on. But it still boots through GRUB, runs the stock Asahi kernel, installs from an unsigned `TrustAll` repository and lacks the encryption lifecycle.

Mac owners get different systems depending on which installer and repository they used. Three package sets are live: mx-mac's `omarchy-dev`/`omarchy-settings-dev` plus `omarchy-mac-boot`, and the collaboration trio `omarchy`/`omarchy-settings`/`omarchy-mac` built from `quattro-upstream`. None of them is official Omarchy. The omacom installer repository is an extraction taken at 2.0.4, nine installer changes behind. Apple-specific decisions keyed on `aarch64` leak onto Snapdragon (Omarchy Dragon) machines, which share the architecture and the package repository. Upstream maintainers can't accept the Mac work while it rewrites core flows.

## Solution

Converge every Apple Silicon feature from both efforts onto `quattro-upstream` as the single integration branch. Shape it so the generic parts merge into official omacom/omarchy Quattro and the Mac-only parts ship as two packages from the official omacom/omarchy-pkgs repository.

The end state for a Mac owner is:

- official Omarchy (stock `omarchy` + `omarchy-settings`)
- two Mac packages: `omarchy-mac` (runtime hardware support) and `omarchy-mac-boot` (initramfs, encryption, first boot, Limine lifecycle)
- the Aurora kernel with `m1n1-aurora` and `uboot-asahi`, booting m1n1 → U-Boot → Limine
- signed packages only
- installed by the omacom/omarchy-mac-installer app, which matches mx-mac installer 2.0.10

Existing mx-mac, legacy omarchy-mac and `quattro-upstream` tester machines migrate in place through a journaled, resumable transition. mx-mac is then archived. After the upstream merge, omacom/omarchy-mac remains the Mac support project: package sources, Mac tooling and Mac documentation, no longer a desktop fork.

Work starts immediately and agentically: install and test on real Macs now, release when everything is tested.

## User Stories

### Mac owners: fresh installation

1. As a Mac owner, I want to install Omarchy from a macOS app, so that I don't need a USB stick or Linux knowledge.
2. As a Mac owner, I want the installer to refuse unsupported models and name the supported ones, so that I don't damage an unsupported machine or waste time.
3. As a Mac owner, I want plain-language engine failure diagnostics, so that I understand why an install failed and what to try.
4. As a Mac owner, I want to see which channel I'm installing and have it open on Stable, so that I don't install a test build by accident.
5. As a Mac owner, I want the download to continue while I pick a new partition size, so that resizing doesn't restart a multi-gigabyte download.
6. As a Mac owner, I want to choose disk encryption during installation, so that my data is protected from first boot.
7. As a Mac owner who chose encryption, I want the temporary install key replaced by my own password on first boot, so that no factory key can unlock my disk.
8. As a Mac owner, I want a recovery passphrase created during owner provisioning, so that I can recover if I forget my password.
9. As a Mac owner, I want the installed system to boot through Limine with snapshot entries, so that I get the same recovery experience as x86 Omarchy.
10. As a Mac owner, I want the Aurora kernel by default, so that USB4 and all my external displays work.
11. As a Mac owner, I want every package I install to be signature-verified, so that a compromised mirror can't tamper with my system.
12. As a Mac owner, I want microphone, speaker safety, Wi-Fi resume, notch and ambient-light behaviour to work out of the box, so that the Mac feels like a supported machine.
13. As a Mac owner, I want hardware video decode available, so that playback is efficient.
14. As a Mac owner, I want the first desktop session to finish any deferred hardware steps without my help, so that I'm not asked to run commands.

### Mac owners: day-to-day lifecycle

15. As a Mac owner, I want `omarchy update` to keep kernel, initramfs, DTBs, m1n1, U-Boot and Limine coherent, so that an update never leaves me unbootable.
16. As a Mac owner, I want updates to refuse to finish, with a clear message, when post-update boot verification fails, so that I don't reboot into a broken system.
17. As a Mac owner, I want to boot a previous snapshot from the Limine menu and restore it, so that I can undo a bad update the same way x86 users do.
18. As a Mac owner, I want restore to tell me when a snapshot predates my current boot files, so that I don't restore into an incompatible kernel/boot state.
19. As a Mac owner, I want changing my disk password to change the LUKS key first and my login password second, resuming if interrupted, so that my disk and login never disagree.
20. As a Mac owner, I want password sync to apply only to my root volume, so that changing a secondary encrypted drive doesn't change my login.
21. As a Mac owner, I want factory reset to re-key encryption and activate a clean root safely, so that I can hand the machine on.
22. As a Mac owner, I want mic and Wi-Fi fixes to arrive without a boot-stack change, so that small fixes ship quickly and safely.

### Existing users: migration

23. As an mx-mac user, I want my machine to move in place to official Omarchy and official packages, so that I don't reinstall.
24. As an mx-mac user, I want the fork's bundle and channel updaters retired during migration, so that my machine never returns to fork repositories.
25. As an mx-mac user, I want my encryption, snapshots and Limine setup preserved through migration, so that nothing about my security changes.
26. As a legacy omarchy-mac user on GRUB and the Asahi kernel, I want an in-place path to Aurora and Limine, so that I get the supported stack without reinstalling.
27. As a legacy omarchy-mac user, I want my unencrypted system to stay unencrypted during migration, so that the riskiest step isn't forced on me.
28. As a legacy omarchy-mac user, I want the unsigned `TrustAll` repository removed and official trust bootstrapped, so that my machine stops accepting unsigned packages.
29. As a `quattro-upstream` tester, I want same-name candidate packages replaced by official ones even when my candidate version is higher, so that I end on the official set.
30. As any migrating user, I want the transition journaled and resumable, so that a power loss or network failure mid-migration can be continued.
31. As any migrating user, I want a preflight that refuses unsupported states before changing anything, so that I'm never left half-migrated.
32. As any migrating user, I want cached packages, config, a LUKS header backup and ESP/boot backups taken first, so that I can recover if boot fails.
33. As any migrating user, I want the new boot chain staged and verified before the active loader is replaced, so that a failed stage can't brick the machine.
34. As any migrating user, I want administrator configuration and service masks preserved, so that my customisations survive.
35. As any migrating user, I want migration to start only after the official packages are published and promoted, so that I never migrate onto an unfinished set.

### Snapdragon and x86 users

36. As a Snapdragon (Omarchy Dragon) user, I want Apple packages, repositories, initramfs hooks and migrations never applied to my machine, so that sharing aarch64 with Macs can't break me.
37. As a Snapdragon user, I want `pacman -S linux` and dependencies on `linux` never to resolve to the Apple kernel, so that I keep my own kernel.
38. As a Snapdragon user, I want Apple-only repositories absent from my pacman configuration, so that Apple packages can't be selected.
39. As a Snapdragon user, I want encryption dispatch points I can plug a Qualcomm implementation into, so that Dragon can adopt the same lifecycle.
40. As an x86 user, I want the generic LUKS, password and initramfs improvements without behaviour regressions, so that upstream changes made for Macs help me too.
41. As an x86 user, I want dispatch points to be no-ops on my platform, so that Mac code never runs on my machine.

### Maintainers and reviewers

42. As an upstream Omarchy maintainer, I want Mac support to arrive as generic interfaces plus small dispatch points, so that I review platform-neutral code and not Mac boot logic.
43. As an upstream maintainer, I want one platform detector returning `apple-silicon`, `qualcomm`, `generic-aarch64` or `generic`, so that platform decisions are consistent and testable.
44. As an upstream maintainer, I want the `HOOKS` baseline to be composable and ordered, so that platform fragments add hooks instead of being overwritten.
45. As an upstream maintainer, I want upstream migrations for Mac users to be one idempotent dispatch line, so that the migration stream stays small.
46. As an omarchy-pkgs maintainer, I want Mac recipes restricted to aarch64 and the edge channel in their first merge, so that CI can't publish them further by accident.
47. As an omarchy-pkgs maintainer, I want Mac recipes pinned to exact omarchy-mac commits, so that builds are reproducible and reviewable.
48. As an omarchy-pkgs maintainer, I want promotion to be an explicit channel widening plus a scoped aarch64 advance, so that promotion is deliberate.
49. As an omarchy-pkgs maintainer, I want Hyprland rebuilt explicitly whenever the carried aquamarine changes, so that the rebuild isn't lost to aarch64-blind automation.
50. As a Dragon maintainer, I want to co-author the detector and settings-profile changes, so that Qualcomm fixtures and needs are covered.
51. As the Mac maintainer, I want package sources, Mac tooling and Mac docs in one repository, so that the whole Mac lifecycle has one home.
52. As the Mac maintainer, I want every design and PR reviewed by a second model before merge, so that mistakes surface early.
53. As the Mac maintainer, I want the mx-mac fork frozen to security and boot fixes, so that features aren't ported twice.
54. As the Mac maintainer, I want a gap audit of the draft boot-convergence PR against mx-mac, so that nothing from either side is lost.
55. As the Mac maintainer, I want the aquamarine CRTC patch submitted to hyprwm, so that the carried package can be dropped.

### Installer and release

56. As a tester, I want the installer to keep the mx-mac signing identity and catalog hosting for now, so that I can test immediately without omacom Apple developer setup.
57. As a release manager, I want installer identity and hosting in one build configuration, so that moving to an omacom identity later is a config change.
58. As a release manager, I want the image builder to consume signed candidate packages pinned to one `quattro-upstream` commit, so that each image is reproducible and traceable.
59. As a release manager, I want the image inspected (initramfs, DTBs, m1n1, U-Boot, Limine) before it reaches a catalog, so that broken images never ship.
60. As a release manager, I want test catalogs isolated from stable ones, so that testers can't leak unqualified images to users.
61. As a release manager, I want VM acceptance evidence exported with hashes, and hardware cold-boot evidence on M1 and M2, before any promotion, so that releases are qualified on real hardware.
62. As a contributor, I want the plan and decisions recorded in the repository, so that agents and humans work from the same source.

## Implementation Decisions

### Repositories and ownership

- **omacom/omarchy-mac `quattro-upstream`** is the only integration branch for Apple Silicon work. Draft PR #503 (boot/encryption convergence into a package-owned boot subtree), with the owner's fixes, is the base. Remaining mx-mac functionality is ported on top.
- **omacom/omarchy-mac after the upstream merge** stops being a desktop fork. It holds:
  - the sources of the two Mac packages, each independently versioned with its own tests
  - all Mac tooling: release orchestration, Aurora pin policy, VM and hardware acceptance, evidence manifests
  - Mac documentation, including this plan
- **omacom/omarchy-pkgs** is the only published package repository. Mac recipes are commit-pinned to omarchy-mac and signed. omarchy-mac/omarchy-pkgs-aarch64 and the owner's fork lanes remain for specific testing only.
- **omacom/omarchy** receives only generic changes. Changes that affect aarch64 as a whole are co-authored with the Dragon maintainers.
- **omacom/omarchy-mac-installer** receives the mx-mac 2.0.10 installer port, merged straight away since it has no users yet. The draft Limine/image-builder PR #2 is rebased onto the port afterwards.
- **maralcbr/omarchy-mx-mac** is frozen to security and boot fixes now, and archived after its users migrate.

### Package set

- The three collaboration packages (`omarchy`, `omarchy-settings`, `omarchy-mac` built from `quattro-upstream`) reduce to **two Mac packages**: `omarchy-mac` and `omarchy-mac-boot`. The forked `omarchy`/`omarchy-settings` disappear once `quattro-upstream`'s generic changes are in omacom/omarchy; they are never published on omacom.
- `omarchy-mac` and `omarchy-mac-boot` stay separate. Boot changes carry a cold-boot hardware gate and own initramfs/encryption; runtime fixes (mic, Wi-Fi) must not wait on that gate. They talk through versioned interfaces.
- `omarchy-settings-asahi` (never published) is superseded by `omarchy-mac`. The obsolete `omarchy-apple-boot` and `omarchy-first-boot` recipes are removed, and remaining references are retargeted to `omarchy-mac-boot`.
- **Kernel:** Aurora only, going forward. `linux-aurora` drops `provides=linux` and keeps its `linux-asahi` and `WIREGUARD-MODULE` provides. `linux-asahi` is Apple-only by nature, and ALARM's `linux-aarch64` and two DKMS packages already use the generic `linux` name. Kernel tooling discovers kernels by `pkgbase`, not provides.
- **First merge of every Mac recipe** (`omarchy-mac`, `omarchy-mac-boot`, `linux-aurora`, `m1n1-aurora`, `uboot-asahi`) carries `arch=('aarch64')` and edge-only channel membership. Omarchy-pkgs CI bypasses `skip_build` and publishes on merge, so the restrictions must be present before the build is enabled.
- **Builds** run on the existing self-hosted builder under emulation; kernel build time is accepted for now.
- **Promotion** to rc/stable happens after M1 and M2 cold-boot qualification. It is a channel widening plus a scoped aarch64 channel advance.
- **aquamarine:** carried as 0.15.1 with only the owner's CRTC re-read patch (the other patch shipped upstream in 0.15.1). It is aarch64-only and edge-only, with a pkgrel above ALARM's. Hyprland is bumped and rebuilt explicitly alongside it, and aarch64 rebuild detection is added. The owner submits the patch to hyprwm, and the carry is dropped once hyprwm releases it.
- Apple scoping in a pacman repository relies on Apple-only package names, no generic provides, nothing generic depending on Mac packages, and no non-Apple package list naming them. A separate Apple-only repository is not needed.

### Platform isolation

- One upstream detector, **`omarchy-hw-platform`**, returns `apple-silicon | qualcomm | generic-aarch64 | generic`. It reads device-tree identity with a proc/sysfs fallback and fails when the evidence contradicts itself. The existing Apple and Qualcomm predicates become wrappers.
- Every Apple-labelled gate currently keyed on CPU architecture moves to the detector. Legitimate architecture checks (ABI, binary availability, repository `$arch`) stay.
- Image builds declare their target platform in a root-owned build manifest. Host device-tree identity never decides an image target. Live privileged operations ignore environment overrides.
- **`omarchy-settings` is one aarch64 build that selects its profile at runtime** by platform. Package-time stripping of drop-ins and templates on aarch64 is replaced by runtime selection.
- Package lists are composed as base + architecture + platform. Only the Apple profile adds Asahi repositories and Apple packages; only the Qualcomm profile adds Qualcomm firmware.
- **mkinitcpio:** the late unconditional `HOOKS` reset is replaced by an early platform baseline plus ordered additions. Apple fragments are gated inside `omarchy-mac-boot`; Qualcomm fragments stay Qualcomm-gated.
- A resident pacman pre-transaction guard in `omarchy-settings` aborts transactions that install packages tagged for another platform. It must be installed before the first hardware transaction. Mac services and entrypoints re-check the platform when they activate. The guard lands with the upstream detector work, not as a prerequisite for the edge recipes.

### Encryption, provisioning and boot lifecycle

- All mx-mac encryption features are ported: in-place LUKS conversion in the initrd, `install.conf` handoff, first-boot re-key, recovery passphrase, temporary-key removal, password sync and factory reset.
- **Layering:**
  - **Upstream keeps orchestration:** the owner wizard, account creation, generic LUKS discovery, retry journals, locks, snapshots, the migration runner and the update flow.
  - **Upstream gains a small fixed-operation dispatch interface.** On a platform with no implementation, optional operations are no-ops and required ones fail explicitly. Qualcomm can implement the same interface.
  - **`omarchy-mac-boot` implements the Apple operations** as root-owned entrypoints:
    - provisioning prepare/commit/verify
    - firmware ordering
    - boot keys
    - ESP selection
    - Limine/U-Boot deploy and rebuild
    - factory-reset prepare/verify/rollback
    - post-update boot verification
- **Generic upstream improvements** (benefit x86 too):
  - raw LUKS parent discovery
  - durable retry journals
  - staged-key cleanup
  - resumable password sync that changes LUKS first and applies to the root volume only
- **Boot:** Limine behind m1n1 → U-Boot on every Mac. GRUB stays available only as a recovery fallback during transition.
- **Snapshots** use the x86 Limine path (snapshot entries plus boot-and-restore). Mac-specific boot-coherence checks cover the ext4 boot partition, the device-tree-selected ESP, m1n1/DTBs/U-Boot and post-kernel-update state. The GRUB-era Mac snapshot tools are transition-only.
- **Tiebreak** when both efforts differ: hardware-qualified evidence wins, then the smaller upstream diff, then omarchy-mac's implementation.

### Migration

- A single **journaled transition engine lives in `omarchy-mac-boot`**, called by one small, idempotent, detector-gated upstream migration. Pre-Quattro legacy installs first pass through the existing Quattro upgrade path.
- **Three cohort adapters:**
  - **mx-mac:** swaps the dev runtime pair for the official pair in one transaction, and retires the fork's bundle and channel updaters.
  - **legacy omarchy-mac:** converts a checkout-based install to packages, removes `TrustAll`, moves Asahi → Aurora and GRUB → Limine, and stays unencrypted.
  - **quattro-upstream testers:** explicitly replaces same-name candidates, including those versioned above stable.
- **Ordered steps:**
  1. Preflight refuses unsupported states.
  2. Back up cached packages, configuration, the LUKS header and the ESP/boot partition.
  3. Bootstrap the official keyring independently.
  4. Prefetch and verify the complete signed package set.
  5. Set official repository precedence and remove legacy trust settings.
  6. Run the package transaction.
  7. Replace the Asahi kernel/m1n1 with the Aurora counterparts plus U-Boot, and rebuild DTBs.
  8. Stage and verify Limine before replacing the active loader.
  9. Reboot and verify.
  10. Retire compatibility state.
- **Transition rules:**
  - Package renames are done by explicit transactions naming the official packages, never by global `replaces` rules.
  - Administrator configuration is preserved.
  - Fresh-image provisioning markers are never armed on existing machines.
- Migration activates only after the upstream merge, signed publication, channel promotion and cohort acceptance.

### Installer and images

- The installer port brings mx-mac 2.0.10's behaviour: supported-model records with names on refusal, engine failure diagnostics, channel display with Stable default, two channels (stable, rc), continued download during resize, encryption choice via `install.conf`, and the persistent privileged helper.
- For immediate testing, the installer keeps the mx-mac bundle identity, team identity, owner-held catalog signing key and existing catalog hosting. Identity and hosting live in one build configuration so the move to omacom is a config change.
- mx-mac's image builder moves into the installer repository's image-builder area. It is adapted to import signed candidate packages (reusing PR #2's authenticated candidate importer) instead of running the fork's runtime installer. It pins the trio and the full boot dependency set to one `quattro-upstream` commit, including the minimum `omarchy-mac-boot` and Limine mkinitcpio hook versions the Limine enablement requires.
- Images built from the mx-mac runtime serve only as an installer baseline. The target is an image from `quattro-upstream`.

### Sequence (starts immediately)

1. Plan recorded in `quattro-upstream` docs.
2. Installer 2.0.10 port on omacom/omarchy-mac-installer; rebase PR #2.
3. Gap audit of #503 against mx-mac; land #503 with fixes.
4. Mac recipes into omacom/omarchy-pkgs edge, under the locks above.
5. First test image from `quattro-upstream`: M2 Max fresh install, then M1 Pro.
6. Port remaining mx-mac features onto `quattro-upstream` behind dispatch points.
7. Upstream generic PRs, in order:
   1. platform detector, generic ARM fixes, profile/package/repository selection
   2. composable boot configuration and generic LUKS/password fixes
   3. lifecycle dispatch interface
   4. migration caller
8. Migration engine and cohort adapters.
9. Promotion after M1 and M2 cold boot; activate migrations; archive mx-mac.

## Testing Decisions

- **A good test exercises external behaviour at the highest available seam:** what a Mac owner's installed system does, what a pacman transaction resolves, what a command outputs. Not internal functions or file layouts. Tests assert outcomes such as "boots with Limine and an unlocked LUKS root", "resolves to linux-aarch64 on a Qualcomm fixture" or "resumes after interruption at step N", never implementation steps.
- **Primary seam: image → installed-system acceptance.** A built image is installed and booted in a KVM VM on the test Macs. The harness verifies:
  - first boot, encryption conversion and re-key, second boot
  - update with boot verification
  - snapshot boot/restore
  - password change, factory reset
  - each migration cohort, including interruption and resume at every journal step

  Prior art: mx-mac's fresh-install and image VM acceptance suites, which export hashed evidence per run.
- **Secondary seam: runtime shell suite with platform fixtures** (Apple, Qualcomm, unknown-aarch64, x86) for:
  - the detector
  - dispatch no-op/required-failure behaviour
  - settings profile selection
  - composed `HOOKS` for every platform
  - migration gating

  Prior art: the existing Apple, Snapdragon hardware and pacman-aarch64 shell tests in the runtime suite, and the add-on package's standalone tests.
- **Secondary seam: package transaction resolution in a disposable aarch64 root** against current ALARM/asahi-alarm and omacom databases. It covers:
  - resolved closures per platform
  - `linux` provider resolution
  - forbidden packages and repositories
  - file ownership across runtime/settings/add-on/boot packages
  - equal-version and locally-newer upgrades

  Prior art: omarchy-pkgs PR build checks and the collaboration builder's ownership and schema checks.
- **Lint:** reject Apple/Qualcomm gates keyed only on CPU architecture, with a reviewed exception list for ABI checks.
- **Installer:**
  - existing Swift unit tests and catalog signature verification
  - an end-to-end install on the M2 Max for every installer PR that changes the engine, catalog or payload contract
- **Hardware qualification (not a test seam, a promotion gate):** cold boot, external displays, USB4, audio, Wi-Fi resume and suspend on the M1 Pro and the M2 Max, following the hardware validation runbook. VM success never substitutes for it.
- **x86 regression:** the upstream suite plus encrypted-install VM tests on the x86 Proxmox worker for every upstream generic PR. Upstream CI and review on top.
- **Not gates** (owned by others):
  - Snapdragon runtime testing
  - legacy omarchy-mac cohort testing on a spare partition
  - Snapdragon package-resolution testing

## Out of Scope

- Encrypting existing unencrypted legacy omarchy-mac machines in place during migration (a later opt-in).
- An interim forked `omarchy`/`omarchy-settings` on omacom before the upstream merge.
- The Asahi kernel as a default or supported lane going forward.
- A separate Apple-only pacman repository or infrastructure changes to omarchy-pkgs repository naming.
- The portable ZIP / temporary-worker installer variant.
- M3 support, Touch ID, MLX, and Secure Enclave disk encryption (separate workstreams).
- Moving the installer to an omacom Apple developer identity and catalog hosting (a config change later).
- Snapdragon feature work beyond the shared detector, dispatch and settings-profile interfaces.
- Adopting the experimental package pool.

## Further Notes

- Decisions that depend on others are recorded at the end of the work:
  - hyprwm acceptance of the CRTC patch
  - Dragon co-authorship timing
  - omacom Apple developer identity
  - legacy and Snapdragon cohort testing
- Workspace conventions apply:
  - releases rebuild only what changed
  - VM acceptance uses the existing evidence export
  - commits carry the owner's identity
  - the owner signs installer catalogs
  - hyprwm patches are submitted by the owner
- **Verified facts this plan relies on** (as of 2026-09-25, Brisbane):
  - mx-mac is based on upstream v4.0.4 (500 behind / 1029 ahead of Quattro).
  - `quattro-upstream` is 113 behind / 84 ahead of Quattro.
  - omacom's `linux-aurora` recipe is skip-build and edge/rc.
  - Upstream's `HOOKS` drop-in overwrites earlier platform fragments.
  - mx-mac's password sync changes login passwords before LUKS.
  - ALARM ships aquamarine 0.15.1-1.
  - The omacom installer extraction is at 2.0.4.
- **Debate record:** positions were debated with a second model over five rounds. Its corrections are folded in: upstream already owns LUKS re-key, stable on mx-mac is Aurora, CI ignores `skip_build`, aarch64 rebuild detection is blind, and `linux-aarch64` provides `linux`.
