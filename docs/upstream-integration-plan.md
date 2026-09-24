# Apple Silicon upstream integration plan

Shared working plan for bringing Apple Silicon support into upstream Omarchy. Updated September 19, 2026. Use this document to agree how the pieces fit together; use the existing workstream cards to track implementation and validation.

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

Prefer reusing [Marcelo's macOS installer](https://github.com/maralcbr/omarchy-mx-mac/tree/main/apps/omarchy-apple-installer) for its interface and Apple boot preparation alongside suitable encrypted-installation work from [omarchy-mac-iso](https://github.com/omarchy-mac/omarchy-mac-iso). Keep the installer separate from the desktop integration repository and preserve history and attribution when extracting existing code. Agree its shared repository home and the reusable Linux interfaces with Marcelo and the maintainers.

Marcelo and Eryk have been working on the macOS installer. Wes has documented the strategies used by the `omarchy-mac-iso` encrypted installer. That documentation is an input to the shared design.

**Marcelo and Eryk, with the Linux installer contributors:** first describe the installer working today—source/runtime branch, image, package set, tested machines and try/install flows, including whether it has been tried with #9835 or the distilled branch. Then propose the shared home, macOS-to-Linux handoff, artifact delivery and ownership of boot updates and recovery. **Wes:** please help review that proposal against the encrypted-install strategies you documented; any implementation role remains to be agreed. The lifecycle below is the intended design to validate against those implementations, not a claim that the current app already performs it.

Linux root and user data must be encrypted. Identify the boot components that remain unencrypted; keep encryption credentials out of logs, the temporary installer and unencrypted boot files.

1. From macOS, prepare Apple boot and allocate the Linux extent. Place the temporary installer at its tail, with the target system ahead of it. APFS resizing remains a macOS operation.
2. Record the disk, partition identities, geometry and artifacts in a handoff manifest. Validate them before target writes; store no secrets in the manifest.
3. Boot Linux, collect the passphrase and create LUKS2 with the agreed Btrfs layout.
4. Install the recorded signed package set, including `omarchy-mac` before hardware setup, and run shared system/user provisioning.
5. Boot the encrypted installed system independently of the temporary installer and verify that independence.
6. Delete only the recorded installer partition, then grow the root partition in place, the encrypted mapping and the filesystem in that order.

Keep the temporary installer until independent boot succeeds. Installation and reclamation must be retryable, checking actual disk state before each mutation. Test interruption and recovery, including snapshot restore with matching boot files and kernel modules. The [recovery constraints](upstream-integration-reference.md#installer-recovery-constraints) retain the detailed checks.

The existing bootstrap can remain a developer/recovery route. The recommended public installer must meet the encrypted lifecycle; the plan does not require two equally supported public installers.

## Kernel, graphics and hardware scope

Asahi is the first validation baseline. Develop an opt-in Aurora preview with its own recorded package set, supported models, updates and recovery. Keep kernel choice independent of the desktop channel and preserve the default for people who have not opted in. Fresh preview installation and switching an existing system require separate evidence.

Marcelo's [public installer documentation](https://github.com/maralcbr/omarchy-mx-mac#omarchy-for-apple-silicon-macs), read September 19, reports an Aurora RC option for particular M1 Pro and M2 Max models. We have not validated that path against the distilled branch or package candidate. Confirm its exact builds and behavior before adopting it into the shared delivery path.

**DJ, Eryk, Ryan Murray and other kernel/graphics contributors, with Marcelo:** please propose the baseline and preview stacks here. Identify the compatible kernel, modules, headers, firmware/boot components and Mesa builds; named models; update and fallback behavior; and physical-hardware acceptance checks. Explain how the Apple proposal fits the wider unified-kernel initiative. Audit `linux-asahi` assumptions and distinguish running, installed and next-boot kernels.

**M3 is a candidate for labelled early support in the first release**, potentially without GPU acceleration, subject to package availability and testing. Asahi's [September announcement](https://asahilinux.org/2026/09/m2-episode-1/) describes M3 laptop/iMac support and limitations; it does not establish what our ALARM package set delivers. Naeem is preparing the Hyprland software-renderer fix PR and following its review toward a merge. Record the delivering package, eligible models, usable-desktop results and install/update/recovery evidence before offering this path. M3 MLX/ANE support is a separate capability, not a prerequisite for a software-rendered desktop.

**DJ:** please describe how the working Touch ID implementation joins the shared system: source and packages, kernel/userspace dependencies, tested models, enrollment and authentication. Keep any Secure Enclave disk-encryption work distinct from biometric authentication.

## Video acceleration

Chris Kearney is contributing decoder fixes and maintaining the VA-API driver fork, building on the existing Andreas/Miguel work. The first-release proposal covers H.264, HEVC Main/Main10 and VP9 8/10-bit hardware decoding through VA-API. Encoding is outside these submissions.

### Sources and packages

- [omacom/linux#10](https://github.com/omacom/linux/pull/10) contains the AVD kernel changes and currently targets `tb`.
- [omarchy-pkgs-aarch64#53](https://github.com/omarchy-mac/omarchy-pkgs-aarch64/pull/53) updates the Mac package to Chris's [libva-v4l2_request fork](https://github.com/iconidentify/libva-v4l2_request). Both PRs are ready for review.
- Firmware comes from Asahi ALARM's `avd-fw`; [package PR #63](https://github.com/omarchy-mac/omarchy-pkgs-aarch64/pull/63) removes the duplicate Omarchy recipe. The kernel driver, firmware and VA-API userspace driver are all required.

The `libva-v4l2_request-avd` recipe [already exists in `omacom/omarchy-pkgs`](https://github.com/omacom/omarchy-pkgs/tree/master/pkgbuilds/libva-v4l2_request-avd), where it still builds sofus13's 1.3 release. Create a new `omacom/libva-v4l2_request` source repository for Chris's work, preserving its history and his maintainer access, subject to org approval. Development continues in [Chris's fork](https://github.com/iconidentify/libva-v4l2_request) until the shared repository is ready.

Update the existing `omacom/omarchy-pkgs` recipe to build a pinned, tested revision from the new source repository in place of sofus13's release. Point the `omarchy-pkgs-aarch64` recipe at that same revision and publish a version that supersedes the existing package. Mac installations currently install this package from `omarchy-pkgs-aarch64`; their official Omarchy repository is configured for database sync only, so changing the upstream recipe alone will not update them.

### Tested so far

The submitted AVD module and userspace package were tested together on a 13-inch M1 MacBook Pro running Asahi `7.1.13-3-1-ARCH`. All 433 selected baseline videos passed, along with mpv OpenGL playback, seeking, concurrent clients, recovery after interruption and an uninterrupted one-hour soak. The [qualification report](https://github.com/iconidentify/omarchy-m1-video/blob/fb2f8678e052c42624bfb437a9bd263c5d9cc333/docs/evidence/m1-submission-2026-09-21/README.md) records the exact revisions, selected tests and limitations.

The complete release kernel still needs to be built and booted. Other M1/M2 models need testing before we claim support. Experimental Chromium testing still shows a color mismatch; browser acceleration remains unfinished.

### Getting it into the release

Ryan/DJ: please confirm whether `tb` is the right integration branch and how these fixes reach the Asahi-based M1/M2 release kernel. An Aurora merge alone would not cover the default Asahi installation.

Scott/Naeem: please confirm who will create the shared driver repository with Chris's maintainer access, update both package recipes, and build and publish the compatible kernel and userspace packages.

Chris will handle the remaining video testing against the agreed release kernel and package set, and keep the results and hardware coverage on the video-acceleration workstream card.

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

`recorded signed packages → encrypted fresh install → independent boot → reclaim installer space → package/kernel update → reboot → recovery`

**Before the assembled Apple Silicon integration is merged upstream, validate a full installation of the combined candidate.** Once its components are integrated, run the complete milestone above from macOS through the encrypted installed system, normal desktop use, updates and recovery, using recorded source revisions and the intended package set. Dev-linked testing during development does not replace this final installation check. Record the tested hardware, results and remaining limits; repeat affected checks if subsequent changes invalidate that evidence. Independent fixes can continue upstream separately.

Use physical Macs for firmware, graphics, audio, suspend, encrypted boot and recovery; ARM VMs for package transactions; disposable storage for interruption tests; and x86 regression checks for shared runtime. Record exact artifacts, repository configuration, hardware and limitations. Each experimental hardware/kernel path needs its own evidence.

Resolve the cross-component questions here, then map implementation to the existing [M+ workstreams](https://app.basecamp.com/5994298/buckets/48646031/card_tables/10263379585). The [card reconciliation](upstream-integration-reference.md#relationship-to-existing-basecamp-cards) preserves the mapping and scope questions, including the duplicate Honeykrisp cards, performance criteria and which additional capabilities are release requirements. Reuse existing discussions and work; agree owners, dependencies and acceptance criteria rather than treating every roadmap card as a release blocker.

The immediate work is to deliver the validated add-on with its matching runtime/settings packages and agree the installer, kernel and MLX interfaces needed for one reproducible encrypted Asahi candidate, with an explicitly scoped Aurora preview proposal. Ready upstream fixes can continue in parallel.

## Current state and evidence

We have taken two steps:

1. **Distilled the existing fork onto upstream Quattro**, incorporating Marcelo's #9835 with adaptations. Published as `quattro-upstream`, this is a common review starting point for the remaining Apple Silicon changes.
2. **Extracted and validated the separate `omarchy-mac` add-on on an M2 Max.** The package refactor is incorporated into the cleaned `quattro-upstream` history. The runtime, settings, add-on and published Steam launcher installed together without ownership conflicts; pending migrations completed. The final package set passed reboot, Wi-Fi, playback and microphone recording/playback. Earlier trials also covered suspend/resume. This is not yet a signed tester release.

The package split is now the implemented integration path. Standalone builds, dependency/ownership checks, scratch upgrade/rollback/retry and the live migration trial are recorded in the [validation report](../plans/omarchy-mac-package-validation.md). Administrator overrides were retained. A WirePlumber restart stall also reproduces with the pre-refactor command; the unsuccessful workaround was excluded. The CLI and all 287 desktop test files now pass, including separate x86_64 and Apple Silicon package-guard checks. Broader hardware coverage, full installer validation and signed package delivery remain ahead.

Installer integration remains unverified against this branch. Marcelo's tested runtime/package baseline needs clarification; the desktop/add-on trial provides no evidence of that integration.

The [supporting reference](upstream-integration-reference.md) retains dated package observations, the upstream merge record, detailed recovery constraints and the Basecamp mapping. This document is the shared plan to develop together.
