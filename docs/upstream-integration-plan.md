# Apple Silicon upstream integration plan

Shared working plan for bringing Apple Silicon support into upstream Omarchy. Installer direction updated September 21, 2026; other observations retain their recorded dates. Use this document to agree how the pieces fit together; use the existing workstream cards to track implementation and validation.

DHH sets the release timeline. His [September 19 update](https://app.basecamp.com/5994298/buckets/48663438/messages/10294496118#__recording_10320638828) targets the first or second week of October, without a committed public release date. Contributors are invited to propose changes to the open sections below through PRs. Named contributors are invitations to develop those sections unless coordination is explicitly agreed; proposed repository homes and interfaces still need maintainer agreement.

## What we are building

One Apple Silicon Omarchy system that testers can install, developed together and brought upstream through focused contributions.

| Piece | Where we work | Intended destination |
| --- | --- | --- |
| Desktop and shared helpers | `omacom/omarchy-mac:quattro-upstream`, distilling the accumulated fork into upstream-reviewable changes | Focused PRs to `omacom/omarchy` |
| Persistent Apple configuration and services | `packages/omarchy-mac/` in that repository; PKGBUILD in `omarchy-mac/omarchy-pkgs-aarch64` | Independently versioned `omarchy-mac` add-on, with official recipe publication and any later source-repository split agreed with maintainers |
| macOS app, Apple boot preparation and encrypted Linux installation | Reuse [Marcelo's macOS installer](https://github.com/maralcbr/omarchy-mx-mac/tree/main/apps/omarchy-apple-installer) and suitable [omarchy-mac-iso](https://github.com/omarchy-mac/omarchy-mac-iso) components in a shared installer project | Companion installer repository, with reusable Linux installation changes proposed to `omacom/omarchy-iso`; exact homes to agree |
| Development packages for testing | Use [omarchy-pkgs-aarch64](https://github.com/omarchy-mac/omarchy-pkgs-aarch64) for the release, completing signing and validation of the compatible package set | Official Omarchy packaging or the appropriate upstream providers as components are accepted |

The collaboration **branch** is what we develop together. The collaboration **channel** is what testers install together. Official ARM packages help, but we still need to distribute desktop and add-on changes that have not landed upstream.

The main release initiatives already cover [M1/M2 launch](https://app.basecamp.com/5994298/buckets/48663438/card_tables/cards/10294470280), a [unified installer](https://app.basecamp.com/5994298/buckets/48663438/card_tables/cards/10296876777), [ARM package infrastructure](https://app.basecamp.com/5994298/buckets/48663438/card_tables/cards/10294467178) and a [unified kernel](https://app.basecamp.com/5994298/buckets/48663438/card_tables/cards/10294477079). This plan connects those outcomes to the Apple work. Marcelo's [release outline](https://app.basecamp.com/5994298/buckets/48646031/documents/10294385193) includes the installer, M1/M2 Pro/Max, GPU support, USB-C displays, Touch ID, MLX and encryption. Agree their acceptance criteria together; the add-on is one part of that system.

## Shared development and upstream contributions

`quattro-upstream` distills `omarchy-mac` into a shared branch for developing upstream contributions. It brings the accumulated work onto upstream Quattro with Marcelo's [#9835](https://github.com/omacom/omarchy/pull/9835) adapted in and now includes the package refactor. It is the shared review starting point, not a completed upstream merge.

Marcelo, Scott, Wes and Naeem will coordinate review of the add-on integration and preparation of the remaining upstream merge. After #9835 lands, compare its actual merged implementation with the distilled branch, reconcile differences and prepare the remaining desktop delta. Ready independent fixes can continue through review throughout this work.

**Keeping the collaboration branch working is part of every merge.** The person merging a PR is responsible for checking the change against the current `quattro-upstream`, including work merged by other contributors, and recording the tested revision and results in the PR. For code changes, run the relevant tests and the normal desktop aggregate suite as a non-root user; changes affecting packages, installation or hardware also need the corresponding transaction, integration or physical checks. Arrange help from other contributors when the required hardware or component expertise is needed.

Before merging desktop/runtime changes, exercise the proposed change combined with the latest collaboration branch through `omarchy dev link <path-to-checkout>` on a test machine. This runs the desktop from that checkout, so check both the changed behavior and ordinary desktop use with the other integrated work present. Use matching development packages where required: dev linking does not rebuild or install the add-on or replace files installed at fixed system paths. Record the source/package revisions, machine and results in the PR. A fresh end-to-end installation is not required for every PR at this stage; changes to installation or package transitions still need checks appropriate to that change.

Use reviewed PRs, with branch protection enforcing review once configured. After merging, check the resulting build and affected integrated behavior. The merger owns follow-through with the author if a regression appears: fix or revert it promptly and withhold affected development packages until it is resolved. The hourly add-on build supplies an artifact and standalone test evidence; it does not establish that the combined desktop, installer and hardware stack works. Keep experiments that cannot yet meet these checks on their own branches.

Keep contributions focused and preserve attribution. Mark new commits with `Upstream-Status: candidate`, `Upstream-Status: experimental` or `Upstream-Status: temporary`; explain the purpose and exit condition for experiments and temporary glue. Preserve shared history by default. Coordinate any exceptional rewrite; submission branches can be cleaned independently.

Installer source, kernel recipes, MLX implementation and repository trust bootstrap belong in their appropriate projects. The upstream desktop submission must also exclude `packages/omarchy-mac/`; its shared interfaces, package dependency and migrations remain separately reviewable. ALS and Steam can be tested in the complete system while receiving separate upstream review. Steam's launcher is supplied by `omarchy-steam-fex`.

The [dated merge tracker](upstream-integration-reference.md#upstream-merge-record) records the existing provisioning, battery, clock/weather, test-runner and Apple foundation contributions. Recheck their status and reconcile accepted changes before preparing submissions.

## The `omarchy-mac` add-on

Persistent Apple defaults and support services belong in the add-on; shared discovery and desktop interfaces stay in Omarchy. The package complements `omarchy` and `omarchy-settings`. It neither provides nor replaces them, selects no kernel, contains no installer and installs no repository trust configuration.

The [source directory](../packages/omarchy-mac/) is independently buildable, with its own version, MIT license, attribution, tests and staging/install script. Preserve original commit references when extracting code. The separate PKGBUILD pins a collaboration-repository commit and packages only that directory. Propose official recipe publication with the packaging maintainers; keep the candidate available through the agreed collaboration channel while that work proceeds.

| First-release component | Package responsibility |
| --- | --- |
| Wi-Fi backend | NetworkManager vendor configuration selecting iwd |
| Wi-Fi resume recovery | Existing restricted helper and package-owned system service |
| Microphone mapping | Existing helper and user service, preserving gain, mute and device choices |
| Headset microphone priority | WirePlumber vendor policy |
| Notch setting | Existing module default, preserving administrator overrides |

Use small explicit system/user setup entrypoints. Fresh Apple installations must acquire the package before hardware setup; existing machines need a retryable transition from the old `omarchy-settings-asahi` requirement. Preserve historical migration compatibility and support offline provisioning and first-session activation without requiring a running user bus during installation. Retain microphone state saving before audio restart.

Validate the runtime/settings/add-on transaction together: each transferred file has exactly one owner, with no broad overwrite workaround. Retire only recognized generated configuration, preserve administrator changes, service masks and intentional disables, and check effective configuration for older overrides. Package publication must be available before setup or migration relies on it.

Bindings, trackpad defaults, Electron workarounds, ambient-light support, HID early-loading, function-key/initramfs handling, boot management, snapshots and installer work stay outside this first package. The wider direction remains package-owned system defaults, a desktop platform layer below user choices, shared hardware discovery and explicit package/boot lifecycle ownership. Those broader changes are separate work, not additions to this initial package scope.

## Development packages for testing

Use [omarchy-mac/omarchy-pkgs-aarch64](https://github.com/omarchy-mac/omarchy-pkgs-aarch64) as the initial collaboration package source for testers and the release. Complete its publication and signing work to provide one reproducible package set for both fresh installations and existing testers. It must include new names such as `omarchy-mac` and the needed branch-built replacements for `omarchy` and `omarchy-settings`. Record exact source and recipe revisions, versions, providers and signers.

These development packages let us test the evolving system together. Their current grouping and repository are provisional; the intended destination is upstream Omarchy and the appropriate upstream package providers. Integrate and validate continuously as parallel work lands, with a recorded compatible set for each distributed build.

Repository precedence must select those intended replacements. Test installation, upgrades, equal versions, locally newer packages and leaving the channel. Coordinate ownership across runtime, settings and add-on packages. Availability of an official ARM package does not establish that it contains the collaboration changes or that the complete installation path is qualified.

The [package pool](https://omarchy-pool.firemanxbr.org/) remains an open question for sub-team experimentation: could it let groups build and test new ideas in independently managed collections, then promote agreed changes into the release package set? Explore build, signing, promotion, retention and rollback with its maintainer. Adopting the pool is not a release dependency; proceed with `omarchy-pkgs-aarch64` while that exploration continues. The [dated package inventory and pool observations](upstream-integration-reference.md#package-delivery-observations) remain inputs to recheck.

Signing and a tested transition away from the existing unsigned repository configuration are release deliverables; [#394](https://github.com/omacom/omarchy-mac/issues/394) records that gap. Trust bootstrap belongs in installer/package configuration. Changing future templates alone does not update existing machines.

**Release and packaging maintainers:** please define the complete tester set delivered through `omarchy-pkgs-aarch64`, name a signing/publication owner, and explain how fresh installs and existing testers reach the same versions and recover from failed updates. With Ryan and upstream maintainers, agree official recipe homes and ARM qualification. Teams interested in the pool can explore its experimental collections separately, including branch-built overrides and the recorded ARM configuration gaps.

## Installer

Qualify [Marcelo's macOS installer](https://github.com/maralcbr/omarchy-mx-mac/tree/main/apps/omarchy-apple-installer) as the primary candidate for installing our shared system. Keep the installer separate from the desktop integration repository and preserve history and attribution when extracting existing code. Agree its shared repository home and reusable Linux interfaces with Marcelo and the maintainers.

The September 20–21 changes supersede our earlier finding that his public installer lacked encryption. The reviewed public history through `7bb6bf476010af0033f6d7ae72d51e0be79d4643` includes the encryption-choice handoff, first-boot LUKS re-key and recovery passphrase, password changes and factory-reset handling ([#183](https://github.com/maralcbr/omarchy-mx-mac/pull/183), [#185](https://github.com/maralcbr/omarchy-mx-mac/pull/185), [#186](https://github.com/maralcbr/omarchy-mx-mac/pull/186)). Offline package-cache installation and chroot image building with deferred hardware setup provide interfaces to evaluate for our package set ([#174](https://github.com/maralcbr/omarchy-mx-mac/pull/174), [#182](https://github.com/maralcbr/omarchy-mx-mac/pull/182)). These are source findings, not independent qualification of a downloadable image or of our collaboration packages.

His image-first flow converts the installed root to LUKS2 at first boot. That differs from our temporary tail installer, which creates an encrypted target ahead of itself and later reclaims its partition. Pause overlapping encryption/provisioning implementation while we qualify his path. Preserve the prepared-install and [omarchy-mac-iso](https://github.com/omarchy-mac/omarchy-mac-iso) work as comparison and fallback inputs; do not retire it until the candidate meets the agreed requirements. If it does, the recommended installation path need not carry a temporary installer or reclamation machinery.

**Marcelo, with the Linux installer contributors:** identify the exact app, image, runtime, boot-package and package-set revisions, tested machines and try/install flows. Then connect a pinned image to our shared runtime/settings/add-on packages and agreed signed repositories. Confirm that installation and subsequent updates keep those intended packages rather than returning to a different fork's runtime. **Wes:** please help compare the candidate with the encrypted-install strategies you documented, including shared-ESP/multiple-root support and rescue workflows; any implementation role remains to be agreed.

### Qualification and architecture decision

1. Record a compatible installer, image and signed package set built from the collaboration revisions, including `omarchy-mac` before hardware setup. Reuse shared system/user provisioning and test the offline/deferred-hardware interfaces against those packages.
2. Validate disk identities, approved geometry and artifact identities before writes. Preserve macOS, Apple recovery and unrelated installations. Agree the Btrfs layout and identify boot components that remain unencrypted.
3. Complete first-boot encryption and owner setup before treating the system as ready for user data. Verify LUKS2, recovery-passphrase acknowledgment, temporary-key removal, login/disk-password changes and factory-reset behavior. Our qualified release path requires encrypted Linux root and user data even though his installer supports an opt-out.
4. Evaluate `omarchy-mac-boot` as the owner of kernel/initramfs and boot-file maintenance. Agree file ownership and package hooks for the selected layout, then test kernel update and reboot. His separate Boot partition and our ISO's UUID-private ESP files are different contracts; do not assume the same hooks serve both.
5. Exercise interrupted encryption, re-keying, provisioning and factory reset on disposable storage, followed by physical-Mac installation, normal desktop use, encrypted reboot and recovery. Record how an incomplete operation resumes or is recovered without losing the installation identity or leaving reusable unlock credentials behind.
6. Record the comparison and architecture decision. Adopt his path if it meets the shared requirements; otherwise identify specific gaps and reuse suitable existing work to resolve them. Retire duplicate machinery only after the chosen combined candidate passes, including any agreed shared-ESP, multiple-root, rescue and try-flow requirements.

Snapper update snapshots and GRUB snapshot boot support are available to evaluate ([#202](https://github.com/maralcbr/omarchy-mx-mac/pull/202), [#203](https://github.com/maralcbr/omarchy-mx-mac/pull/203)). Keep snapshot restore experimental: it is explicitly opt-in because the root rename pair is not crash-safe, and snapshot boot eligibility depends on compatibility with the kernel outside the snapshot. Test both successful recovery and refusal of incompatible snapshots; do not treat a snapshot menu as complete rollback coverage.

The new [first-boot VM harness](https://github.com/maralcbr/omarchy-mx-mac/pull/194) exercises encryption conversion and a subsequent encrypted boot with a generic ARM kernel. Reuse it for the combined candidate where suitable; it does not establish Apple firmware or hardware behavior. The [recovery constraints](upstream-integration-reference.md#installer-recovery-constraints) retain the detailed checks, including conditional reclamation requirements if the tail-installer design is selected.

The next installer milestone is qualification against our installed-system requirements. The existing bootstrap can remain a developer/recovery route; maintaining two equally supported public installers is not an objective.

## Kernel, graphics and hardware scope

Aurora is the intended kernel for the shared system, with source now available at [omacom/linux](https://github.com/omacom/linux). Plan toward Aurora as the launch default. The remaining question is timing: it must work well enough on the agreed launch hardware and deliver the packages needed for installation and ongoing updates in time for launch. Record the package provider, signed artifacts, compatible dependencies and update/recovery evidence. Source availability alone does not establish package delivery or qualification.

Asahi is the backup if launch timing requires shipping before Aurora meets those conditions. If that fallback is needed, retain the planned transition to Aurora and define its package migration, boot-update and recovery checks. Keep kernel choice independent of the desktop channel; qualify fresh Aurora installations and migration of existing Asahi systems separately.

Marcelo's [installer 2.0.7 change](https://github.com/maralcbr/omarchy-mx-mac/pull/197), reviewed September 21, removes the separate RC Aurora option because RC now carries Aurora. This UI change alone does not establish the package delivery and compatibility needed to ship our shared system on Aurora. We have not validated that path against the distilled branch or package candidate. Confirm its exact builds and behavior before adopting it into the shared delivery path.

**DJ, Eryk, Ryan Murray and other kernel/graphics contributors, with Marcelo:** please define the Aurora delivery and qualification work needed for launch, with Asahi as the fallback if timing requires it. Identify the compatible kernel, modules, headers, firmware/boot components and Mesa builds; named models; update and fallback behavior; and physical-hardware acceptance checks. Explain how the Apple proposal fits the wider unified-kernel initiative. Audit `linux-asahi` assumptions and distinguish running, installed and next-boot kernels.

**M3 is a candidate for labelled early support in the first release**, potentially without GPU acceleration, subject to package availability and testing. Asahi's [September announcement](https://asahilinux.org/2026/09/m2-episode-1/) describes M3 laptop/iMac support and limitations; it does not establish what our ALARM package set delivers. Naeem is preparing the Hyprland software-renderer fix PR and following its review toward a merge. Record the delivering package, eligible models, usable-desktop results and install/update/recovery evidence before offering this path. M3 MLX/ANE support is a separate capability, not a prerequisite for a software-rendered desktop.

**Chris and the video-acceleration contributors:** please confirm your scope and propose first-release decoder/encoder capabilities, dependencies, packages, hardware coverage and application tests, building on the existing Andreas/Miguel work.

**DJ:** please describe how the working Touch ID implementation joins the shared system: source and packages, kernel/userspace dependencies, tested models, enrollment and authentication. Keep any Secure Enclave disk-encryption work distinct from biometric authentication.

## MLX and its graphics dependencies

ANE support should ship by default on Apple Silicon, alongside GPU support. The driver should load on supported chips, with the required firmware and device-tree support included in the installation. Model downloads and inference servers remain optional.

The first-release target is GPU inference and ANE support across M1 and M2, including base, Pro, Max and Ultra. As of September 19, the tagged [ANE v0.1.0 release](https://github.com/joshuaswarren/omarchy-ane/releases/tag/v0.1.0) qualifies M1 and M1 Max; M1 Pro and Ultra still need qualification, and M2 support is under development. The broader target remains subject to implementation and per-variant validation before support is enabled by default.

### Release targets

mlx-omarchy v1.0.0 and omarchy-ane v1.0.0 will mark the first Omarchy-ready releases. A fresh installation must run GPU inference and the Parakeet ANE demo on each M1/M2 variant. Both must continue working after a system update and reboot.

Package those versions, or a newer stable pair available at launch. Josh will provide the versions tested together, including the Mesa build and ANE compiler. Performance parity, later-chip support and broader MLX coverage remain separate workstreams.

### Repositories

Josh has offered to transfer [mlx-omarchy](https://github.com/joshuaswarren/mlx-omarchy), [omarchy-ane](https://github.com/joshuaswarren/omarchy-ane) and the [ANE compiler](https://github.com/joshuaswarren/mil-hwx-compiler) to omacom. Development continues in the current repositories until the transfers and his ongoing write access are arranged.

The ANE compiler stays in a separate repository so other projects can use it. It should have its own package, pulled in by MLX wherever compilation is needed. Users should get one installation without setting up the compiler by hand.

Mesa development is in [mesa-1](https://github.com/joshuaswarren/mesa-1/tree/honeykrisp-omarchy), with changes submitted to omacom/mesa and upstream Mesa. Josh currently lacks maintainer or write access to omacom/mesa. DJ or Josh will need that access to maintain the shared branch, ideally both.

### Installation and updates

The installer should deliver the ANE driver and Honeykrisp Mesa build with the system. The Mesa fixes are a dependency of the MLX release and must reach users through normal package installations and updates.

Use omarchy-pkgs-aarch64 for the initial packages, then move them into the official repositories with the rest of the release.

MLX retains a one-command installation that installs the runtime and Python dependencies together. ANE support must be part of the release kernel and boot flow, with driver, firmware and device-tree updates handled through normal system updates. Existing installations should receive the same support without manual boot-file repairs.

### Ownership and coordination

Josh owns the MLX runtime, ANE driver and firmware work, compiler integration, and ML tests. He will coordinate Mesa changes with DJ and the graphics contributors.

Installer, kernel and packaging maintainers need to coordinate with Josh on the default installation, updates and package publication. Scott will be asked to confirm the contacts for those roles. Additional testers are needed for the M1/M2 variants not covered by Josh's hardware.

Current results and remaining work stay on the Local ML and Honeykrisp packaging cards in Basecamp.

## First milestone and existing work

`recorded signed packages → encrypted fresh install and owner setup → independent boot → package/kernel update → reboot → recovery`

Reclaim installer space after independent boot only if the selected design uses a temporary installer partition. Qualify Marcelo's image-first path before deciding whether that machinery is needed.

**Before the assembled Apple Silicon integration is merged upstream, validate a full installation of the combined candidate.** Once its components are integrated, run the complete milestone above from macOS through the encrypted installed system, normal desktop use, updates and recovery, using recorded source revisions and the intended package set. Dev-linked testing during development does not replace this final installation check. Record the tested hardware, results and remaining limits; repeat affected checks if subsequent changes invalidate that evidence. Independent fixes can continue upstream separately.

Use physical Macs for firmware, graphics, audio, suspend, encrypted boot and recovery; ARM VMs for package transactions; disposable storage for interruption tests; and x86 regression checks for shared runtime. Record exact artifacts, repository configuration, hardware and limitations. Each experimental hardware/kernel path needs its own evidence.

Resolve the cross-component questions here, then map implementation to the existing [M+ workstreams](https://app.basecamp.com/5994298/buckets/48646031/card_tables/10263379585). The [card reconciliation](upstream-integration-reference.md#relationship-to-existing-basecamp-cards) preserves the mapping and scope questions, including the duplicate Honeykrisp cards, performance criteria and which additional capabilities are release requirements. Reuse existing discussions and work; agree owners, dependencies and acceptance criteria rather than treating every roadmap card as a release blocker.

The immediate work is to deliver the validated add-on with its matching runtime/settings packages and qualify Marcelo's installer against that package set while agreeing the kernel and MLX interfaces needed for one reproducible encrypted launch candidate. Target Aurora for launch; use the qualified Asahi path only if Aurora hardware qualification or package delivery misses the launch timing, with a subsequent transition to Aurora planned. Ready upstream fixes can continue in parallel.

## Current state and evidence

We have taken two steps:

1. **Distilled the existing fork onto upstream Quattro**, incorporating Marcelo's #9835 with adaptations. Published as `quattro-upstream`, this is a common review starting point for the remaining Apple Silicon changes.
2. **Extracted and validated the separate `omarchy-mac` add-on on an M2 Max.** The package refactor is incorporated into the cleaned `quattro-upstream` history. The runtime, settings, add-on and published Steam launcher installed together without ownership conflicts; pending migrations completed. The final package set passed reboot, Wi-Fi, playback and microphone recording/playback. Earlier trials also covered suspend/resume. This is not yet a signed tester release.

The package split is now the implemented integration path. Standalone builds, dependency/ownership checks, scratch upgrade/rollback/retry and the live migration trial are recorded in the [validation report](../plans/omarchy-mac-package-validation.md). Administrator overrides were retained. A WirePlumber restart stall also reproduces with the pre-refactor command; the unsuccessful workaround was excluded. The CLI and all 287 desktop test files now pass, including separate x86_64 and Apple Silicon package-guard checks. Broader hardware coverage, full installer validation and signed package delivery remain ahead.

Marcelo's recent encryption, provisioning and snapshot work supplies an implemented candidate for qualification. Installer integration remains unverified against this branch: identify the exact tested runtime/package baseline and build the combined candidate. The desktop/add-on trial provides no evidence of that installer integration; merged source changes alone do not establish their inclusion in a released image.

The [supporting reference](upstream-integration-reference.md) retains dated package observations, the upstream merge record, detailed recovery constraints and the Basecamp mapping. This document is the shared plan to develop together.
