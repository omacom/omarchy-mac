# Scoped Quattro encryption and Limine integration — 2026-09-22

Status: checkpointed baseline; source inventory and separate local integration branches prepared. No functional port, new package/image/app build, VM run or physical operation has been performed in this preparation. This is the entry point for the next source implementation, not an encrypted-install qualification claim.

## Branches and preserved baseline

All four component integration branches are named `integrate/quattro-encryption-limine` in their respective repositories. Paths below are relative to `/home/scott/code`.

| Component | New integration worktree | Base |
| --- | --- | --- |
| Desktop/runtime | `omarchy-worktrees/quattro-encryption-limine` | Tested distilled desktop `1c595bb6030c487c0b584f3e192ef9e8b858b821` |
| Package recipes/candidate workflow | `omarchy-pkgs-worktrees/quattro-encryption-limine` | Tested candidate recipe source `5b41ff12fbf97c7fc86a161e58763ebc97e4e2d9` |
| Image builder | `omarchy-iso-worktrees/quattro-encryption-limine` | Checkpoint `cc0bbb5`, parent `ecb213674022352253c1ce766a1ae438c6ea427f` |
| Standalone macOS app | `omarchy-mac-installer-encryption-limine` | Checkpoint `23dc8de`, parent `6f45ad29f75c606a1d0c0657f9f9809cfd23c299` |

Both `checkpoint/m3-validated-20260922` branches contain only the physical-validation summary, evidence digest index and a link from existing validation documentation. Their worktrees are `omarchy-iso-worktrees/m3-checkpoint` and `omarchy-mac-installer-m3-checkpoint`. The builder's implementation remains `40154c5031ff848c0ce06867c12f9daea136fe13`; subsequent commits are evidence records.

The original app and builder branches remain at their original commits. Keep the active `omarchy` dev link on `quattro-mac-live` at `350c46550b99688cdb5224408edd5870de2ca07b`. Leave `omarchy-mx-mac-integration` on `feat/encrypted-live-installer` at `7e2aa96477352e3de75a5f997f22861c8de8d011`, including every dirty prepared-install overlay file. Do not use that dirty branch as an import source. Other package checkouts also contain unrelated work; use only the new package worktree.

## Pinned upstream source

GitHub API was re-queried on September 22; exact query time, PR state, source commits and complete PR file lists are in [the source inventory](quattro-encryption-limine-sources-2026-09-22.json). [The file disposition map](quattro-encryption-limine-files-2026-09-22.json) covers the selected PR union, the complete runtime/app net change list since extraction, and companion package files. Entries are proposed dispositions, not evidence that the files have been ported or that their tests pass here.

- Runtime merged baseline: `5e7a409fae1ddc17433d9408e15153b4fe813f7b` ([#219](https://github.com/maralcbr/omarchy-mx-mac/pull/219)). Proposed source ceiling: open [#220](https://github.com/maralcbr/omarchy-mx-mac/pull/220), head `d418ab7f95e8ba447df4fb368ddd838a5ffc7943`. Use its actual head, not GitHub's synthetic merge SHA.
- Package default branch at query: `02da5b7ac1fa2c762dda0af1484a43b6e7e9267a`. Proposed image reference: open [#194](https://github.com/maralcbr/omarchy-pkgs/pull/194), head `68a61cef1aba768c6aae20a0feda2a42e19de6e8`. This is source-only reference; its own PR still lacks a payload build and macOS reinstall.
- Marcelo's image repository default branch: `268bac16d351a21d867e37565738f458b11cb06c`. Preserve our implemented candidate builder rather than replacing it with his newer package-repository image script.
- Standalone extraction origin: `maralcbr/omarchy-mx-mac` at `4db862da7a0957758c504c5a3e041202019dbabf`, prefix `apps/omarchy-apple-installer/`. Runtime #185 predates this app extraction but its Linux behavior was not imported with the app.
- Destination desktop still resolves to tested `1c595bb6030c487c0b584f3e192ef9e8b858b821`. Destination package main has advanced to `78bf4a2d659187c10c722d8d0e8c41dd9e5e3726`; the new package branch intentionally starts from the tested recipe revision, so later main changes require their own comparison before any eventual merge.

Read upstream [Limine design at the pinned source](https://github.com/maralcbr/omarchy-mx-mac/blob/d418ab7f95e8ba447df4fb368ddd838a5ffc7943/docs/apple-silicon-limine.md). The boot chain remains m1n1 → U-Boot → EFI Limine → UKI. `/etc/default/grub` remains a derived-command-line input even without an active GRUB loader. Snapshots do not restore m1n1 or U-Boot on the ESP.

## Functional slices and ownership

| Slice | Source and destination | Scope and dependency |
| --- | --- | --- |
| Owner encryption lifecycle | Runtime #185: `bin/omarchy-provision-owner`, `omarchy-drive-password`, `omarchy-system-factory-reset`, boot checker and six associated tests | Adapt Apple LUKS owner/recovery slots, retry state, temporary-key removal and reset transaction to the distilled runtime. Preserve existing generic behavior and raw LUKS lookup. Pair with the package initrd conversion unit. |
| Boot verification | Runtime #192 and #199, then #211/#219 | Carry depmod tolerance and systemd `sd-encrypt` recognition before the Limine UKI/menu checks. Verification must test actual kernel/initrd and entry content. |
| Limine activation/update | Runtime #211, #217, #218, #219, #220: `omarchy-mac-{limine-active,limine-cmdline,limine-deploy,boot-update}`, `install/hardware/apple/limine-boot.sh`, tests | Adapt a complete activation transaction, real failure rollback, missing-template refusal, no-GRUB operation, preserved ESP staging and foreign-identity menu reset. Do not cherry-pick #211 alone. |
| GRUB compatibility | Runtime #208/#209/#210/#219 `grub-console.sh` and tests | Carry the GOP fix and required cmdline generation with provenance from #209. Selectively adapt prerequisites; font/theme/splash polish is not required for the encryption slice. No second one-off GRUB fix. |
| Snapshots and reset | Runtime #202/#203/#205/#211 and tests | Inspect older GRUB fallback dependencies, but use shared Limine snapshot dispatch on the new candidate. Preserve non-Btrfs and offline unit detection. Do not import the old GRUB snapshot service/migrations just because later files reference fallback commands. |
| Fresh-image orchestration | Runtime `omarchy-install-asahi-fresh`, `install/helpers/mac-image-build.sh`, platform manifest and #212/#213/#218/#219 tests | Translate orchestration/validation contracts into the existing image builder and target setup interfaces. The distilled runtime does not need Marcelo's entire fresh installer, platform release verifier or channel system. |
| First-boot/conversion package | `pkgbuilds/omarchy-mac-boot/**`, package tests | Proposed separate `omarchy-mac-boot` package owns initrd conversion, vendor firmware/HID ordering, first-boot gates, hooks and reset support. Do not place these in kernel-neutral `packages/omarchy-mac`. Adapt repository trust behavior before admitting this package. |
| ARM64 boot tooling | `limine-mkinitcpio-hook`, `limine-snapper-sync`, `uboot-asahi` recipes and settings template | Carry ARM64 UKI patch, activation gate and no interactive mkinitcpio wrapper; retain the menu template on ARM64. Resolve the full signed package closure before building. |
| Image production | Package #194 `bin/build-mac-image`, `bin/mac-image-check`, `test/mac-image` | Port behavior into `builder/asahi-stages/finalized-boot.sh`, orchestration/input declarations and package/installed-system verification. Activate after final mkinitcpio, strip builder machine identity/history, preserve empty `esp/omarchy`, verify actual Limine bytes, menu entry and UKI sections. Do not copy the separate builder wholesale. |
| Disposable VM evidence | Runtime #193/#194/#214 and `test/vm/mac-image/{README.md,run}` | Adapt to private authenticated inputs and this image layout. Preserve the generic guest kernel and guest boot config; distinguish plain, conversion and second encrypted boot. It cannot test the Apple boot chain. |
| App/engine | 16 app paths changed since extraction, from #195/#197/#198 | All net changes concern version/channel retirement and related tests; no engine delta exists. Exclude from this encryption/Limine scope. Existing `InstallConf` choice and ESP writer are already extracted; preserve `.17`, standalone paths, trust and channel separation. Revalidate consumption of the future image. |
| Add-on | `packages/omarchy-mac/**` | Preserve Wi-Fi/iwd, resume, microphone/headset and notch ownership unchanged. No kernel or bootloader dependency added. |

Generic menu hunks may be adapted for snapshot dispatch; omit Marcelo's Stable/RC channel policy. `bin/omarchy-channel-set`, `omarchy-update-asahi-bundle`, update-keyring changes, release records and upstream distribution documents are references or exclusions, not a runtime import list. Existing-user migrations are deferred: prepare fresh-image behavior first, then review any eventual migration separately against the destination migration guide.

## Package pins and transaction review

These are source recipe identities, not an authenticated complete binary lock. At package head `68a61cef1aba768c6aae20a0feda2a42e19de6e8`:

| Recipe | Version / provenance |
| --- | --- |
| `omarchy-mac-boot` | `20260921-9`; initial consolidation #155 `bc8858776de2989a30c71e2791c0737d4048c8b0`; encryption fixes #170 `a59e0faf13b5c043b35f2bb2dabde6e3bce5d3ce` |
| `limine-mkinitcpio-hook` | `1.36.0-3`; ARM64 UKI patch, unattended wrapper removal |
| `limine-snapper-sync` | `1.30.1-1`; ARM64 recipe |
| `uboot-asahi` | `2026.07.asahi2-3`; quiet-console patch; Asahi archive SHA256 recorded in recipe |
| Settings template | #190 `62eba44c3b55564832b2baf55fea30d85af50dbe`: keep `/usr/share/omarchy/default/limine/limine.conf` on aarch64 |
| Limine package | Upstream uses ALARM `limine`; exact archive/version/signature still needs resolution against the selected dated platform snapshot |

Package #182 `f8503146010497e4e417dd402871237d81e0eb62` supplies the Limine/U-Boot recipes, #185 `d3b994e015e2720ae9f8974d012b6c44e6638798` adds U-Boot build metadata, and #186 `3c93301b313a32745bcf7546508ad561905958db` gates tooling until activation. Include these source contracts together. The Aurora kernel/m1n1 three-package set in the M3 checkpoint is a separate trial identity, not proof of a coordinated Limine image.

The boot package replaces/provides/conflicts with `omarchy-apple-boot` and `omarchy-first-boot`. It ships vendor firmware files and first-boot drop-ins in addition to encryption. Compare every installed path from the complete old/new package transaction; confirm removals cannot unlink the active mkinitcpio drop-ins or firmware helpers. Its declared dependencies omit explicit `cryptsetup` although the initcpio hook needs it; ensure the target closure supplies it, with package ownership and build-time hook tests. Do not claim a metadata defect without checking the full dependency closure.

The first-boot script embeds and locally signs Marcelo's repository key `C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC`. Exclude that key and adapt the keyring lifecycle to the existing target policy; do not substitute a candidate signer as installed-user trust. Preserve candidate public policy `FBD6874D423C418DDB6D143EECE19CDDE306DBD2` / signer `D791ED0C72439D9F8757421258043B2770A25762` and the separation of mandatory build-input signatures from current target feed policy.

Extend `scripts/build-quattro-image-inputs.py`, its signing/verifying schema and builder `quattro-candidate.py` together for an explicit new candidate package set. Existing schema-3 nine-package receipts must remain reproducible. Preserve disjoint candidate/dependency names, offline closure, paired desktop/settings versions, source markers, receipt digests and installed inventory. No edge workflow, production release, remote key or channel change belongs in this integration.

## Overlap and verification sequence

The destination already includes raw `lsblk -nsrpo NAME,FSTYPE` in owner setup and factory reset, with `test/shell.d/luks-parent-detection-test.sh` (merged #494). Runtime #196 is the corresponding source fix; preserve it while adapting #185. Snapper's `systemctl --root=/ list-unit-files --no-legend` check and `test/shell.d/snapper-test.sh` are already merged (#493); retain them when integrating #205/#211. Passing those focused tests on the destination verifies the overlap baseline only.

1. Port owner/key lifecycle and package conversion/firmware gates with their focused mock tests (`provision-owner-luks`, `factory-reset-luks`, drive-password, boot-check; package `test/omarchy-mac-{boot,encrypt,first-boot,hid-initramfs}`). Test retry/key cleanup and failures without invoking live entrypoints.
2. Port activation/update/snapshot slices with source attribution per commit and focused `apple-limine-boot`, `mac-limine-cmdline`, `mac-boot-update`, snapshot dispatch and existing Snapper/LUKS tests. Ensure open #220 cases are included. Run runtime `test/cli` and `test/shell` once the slice is green.
3. Port the image activation/verification contract and candidate schema. Run focused `test_quattro_candidate.py`, dependency and package-install checks, finalized/installed-system tests; then the builder aggregate suite once. Run package `scripts/self-test.sh` and adapted boot/image tests. Check all package paths in one disposable installation transaction.
4. Preview invalidation before Docker/restoration/compression: runtime/settings and new boot inputs invalidate package closure, target configuration, initramfs/UKI/ESP, image verification and ZIP/catalog identities. Reuse authenticated downloads; never reuse configured/boot checkpoints for changed inputs. App and `.17` engine source remain reusable unless contract testing demonstrates a required change.
5. Resolve and authenticate the complete package set (including Limine and the selected kernel/m1n1/U-Boot), then produce one private image and run the adapted VM plain/conversion/second-encrypted-boot lanes. The original VM `--payload` path does not authenticate inputs; add verification against our retained receipt/manifest before use. It requires disposable loops/chroot/KVM and is not a pure source test.
6. Validate the standalone app against the exact image, unchanged engine and private catalog; use portable tests and macOS debug/release, packaging/signature/unsupported-host checks as applicable. Do not rebuild passed immutable inputs without a changed dependency.
7. Only after coordinated qualification, stage a concrete owner-reviewed M3 installation plan covering encrypted first boot, owner and recovery unlock, temporary-key absence, reboot, update, snapshot boot and restore. No physical authorization is inferred from this preparation or the earlier Aurora experiment.

The preparation itself changes documentation only. Verify JSON/link integrity, documentation diffs and preserved worktree hashes; do not repeat full source suites or image qualification for unchanged implementations. Source pins are a review ceiling, and open PR movement must be reviewed explicitly before replacing them.

Preparation checks on September 22 passed: `env -u NO_COLOR -u LC_ALL bash test/shell.d/luks-parent-detection-test.sh` and the same invocation of `snapper-test.sh`. These confirm existing overlap behavior, not the unported encryption/Limine changes. The file disposition map contains 168 entries.
