# Encryption and Limine source port — September 22, 2026

This is a draft source integration, not a qualified image or an installed change. The active desktop and the physically validated M3 app/builder checkpoints are preserved. All source work belongs to `integrate/quattro-encryption-limine` in its component repository. No production signing keys, new installed trust root, release workflow, remote branch, or physical disk was changed.

## Origins and completed source scope

Runtime changes are selectively adapted from Marcelo's `maralcbr/omarchy-mx-mac` at `d418ab7f95e8ba447df4fb368ddd838a5ffc7943` (open #220, including merged #219). Package payloads and ARM64 recipes come from `maralcbr/omarchy-pkgs` at `68a61cef1aba768c6aae20a0feda2a42e19de6e8` (open #194). The [pinned inventory](quattro-encryption-limine-sources-2026-09-22.json) preserves the original PR/file attribution; this port does not import the upstream branch as a whole.

- Runtime: owner and recovery LUKS slots, retry state and staged-key cleanup; Apple password changes; factory-reset key staging; installed kernel/initramfs boot checks; Limine command-line generation, activation, deployment and update dispatch; installed-package kernel selection. Existing raw LUKS-parent discovery and defensive Snapper configuration are retained.
- Package source: `omarchy-mac-boot` conversion/initrd, firmware/HID ordering, first-boot gates and services; ARM64 Limine entry/snapshot tooling and U-Boot recipes. The original key, standalone image-finalization command and old GRUB snapshot-menu hook are excluded. The add-on stays kernel-neutral.
- Candidate tooling: an explicit `--boot-profile limine` produces a schema-4 thirteen-package set. Schema 3 remains the nine-package default. Settings keep their ARM64 Limine template only in the opt-in profile. Signing and standalone image-input verification accept both profiles under the existing policy and require the complete package set, source markers, archive metadata, single ownership, template and conversion payload. No workflow is switched to schema 4.
- Image boundary: standalone schema-4 verification is implemented, but the image adapter refuses that profile immediately after authentication, before trust changes or package/image work. This prevents an incomplete integration from emitting a misleading candidate. The standalone macOS app and `.17` engine have no source delta in this scope.

## Adaptations and limits

Retrying owner setup with a different password cannot reuse an already-recorded owner slot without authenticating it. State/key staging uses file and directory sync before committing. Missing devices cannot silently complete an unfinished rekey. Password-bearing scripts disable inherited tracing after their metadata header.

Failed Limine reactivation restores the prior defaults, menu, UKIs and pre-hook. Foreign machine-id histories are removed only after successful deployment; the installer's ESP staging directory is preserved. Package first boot invokes the distilled runtime's Limine leaf rather than the excluded monorepo helper. Per-machine keyring setup initializes/populates only the existing platform keyrings; Marcelo's embedded repository certificate and local-sign step are absent, and the candidate signer is not installed as target trust.

Factory reset preserves ESP firmware. A reset whose snapshot kernel differs from the current `/boot` kernel is refused before rebuilding boot files; coordinated cross-kernel reset is not implemented. Same-kernel behavior has fixture coverage. This is an explicit limitation, not evidence that snapshot restore across kernel updates is safe.

## Verification

At the initial source checkpoint, the runtime aggregate exercised 296 shell test files. It initially failed the new privileged heredoc check and CLI metadata placement, plus three unrelated fixtures affected by inherited Git signing and the sandbox's route-lookup restriction. The two source defects were fixed. `test/cli`, the privileged-heredoc/activation tests, and all three affected fixtures then passed; fixture commits used `commit.gpgsign=false`, and the QR fixture used read-only host route access. No production Git signing key was used. The entire aggregate was not rerun at that checkpoint; the review follow-up below supersedes that runtime result.

Focused encryption, recovery-slot retry, reset rollback, cross-kernel refusal, password, Limine activation/update/cmdline, raw LUKS lookup, Snapper and boot-check tests passed. A temporary fullscreen terminal displayed the real recovery-key UI with a dummy key; the key, explanatory text and acknowledgement input were visible without clipping. This is desktop terminal verification, not an Apple VT/firmware boot test.

Package checks: `test/boot-source` runs offline staging, conversion source checks, first-boot fixtures and firmware/HID source checks. The new entry point explicitly disables disposable container/block lanes. `scripts/self-test.sh` passed 92 checks; candidate ownership tests passed 16; candidate signing tests passed 13, including real disposable keys for both schemas. The ARM64 template adaptation was also checked against the exact pinned recipe commit `4b60e4cd95972c16fbf3da634522a955cf7bf36c` after baseline recipe preparation. Actual native package compilation and a complete pacman replacement transaction remain untested.

The builder signed-input fixtures passed 31 tests, including schema-4 signatures, missing packages, ownership, exclusion of the upstream key, and refusal before image trust changes. The builder aggregate could not complete in this execution environment: after initializing its exact pinned archiso submodule, the existing lifecycle-wrapper test refused the sandbox-mapped `/` owner (UID 65534), and the runner cancelled remaining tests. The lease ownership check was not weakened. The verification ledger records this failure; the full builder suite is not claimed green. The candidate signing trust files and baseline schema behavior remain unchanged.

## Remaining integration and qualification

1. Port the required GRUB GOP/cmdline compatibility from the recorded #209 provenance, excluding unrelated visual polish. Complete review of activation failure boundaries and cross-kernel snapshot/reset support.
2. Resolve the complete authenticated Limine/platform package closure. Add an opt-in dependency-snapshot contract that excludes all candidate names and the replaced legacy boot packages; reject candidate/dependency/platform overlap. Add native build prerequisites and validate the full package transaction, including removal hooks and firmware ownership. Do not reuse the old nine-package closure as new-image evidence.
3. Wire the existing builder's finalization, including the explicit marker contract below: arm first boot, supply the pinned offline Node input, activate Limine after final mkinitcpio, verify actual EFI bytes/menu/UKI sections, remove builder identity and private keyring state from both root and factory snapshot, and preserve empty ESP `omarchy` staging. Update declared inputs and cache identities. Only then remove the schema-4 image guard.
4. Adapt the VM harness to authenticated private image inputs. Run plain, conversion and second encrypted boot in disposable infrastructure. Source-only conversion checks do not test real reencryption, UKI boot or keyboard availability.
5. Build one private coordinated image; validate the unchanged standalone app/engine against that exact image. Physical M3 encrypted installation remains a separate owner-reviewed operation after image/VM qualification.

The file disposition map remains the complete proposed scope. Its per-file implementation field records only files actually adapted in this source checkpoint; pending/excluded entries must not be counted as imported features.

The [verification ledger](quattro-encryption-limine-verification-2026-09-22.json) records source commits, results, retained log paths and SHA256 digests.

## Review corrections

The follow-up review found a real root-entrypoint regression: the owner provisioning unit has no desktop environment, and reset's sudo re-exec drops it. Both entrypoints again initialize the trusted `/usr/share/omarchy` path when absent; ordinary desktop commands continue to use the session invariant. Clean-environment fixtures cover both entrypoints.

Reset now durably changes the Boot journal to `configured` before adding its temporary keyslot or writing the Boot key, before root activation. File and directory sync failures abort. Provisioning refuses `finished` when either staged key or a persistent `rd.luks.key=` remains. Failed rekey journal writes cannot retire the staged unlock or advance the phase. These are source/failure-injection checks, not physical power-loss qualification of the complete reset/subvolume/boot transaction.

Recovery setup now authenticates the owner, journals a free recovery slot before adding its key, verifies the key, displays it in the foreground, and durably records acknowledgement. Retry revokes/replaces an unacknowledged slot and visibly tells the owner to replace any earlier copy; acknowledged keys survive worker failures without redisplay. A background worker cannot create/display a recovery key. Passwords remain descriptor-only with tracing disabled; cryptsetup failures are retained in the private log. A small real LUKS2 regular-file check also exercises slot reservation, interruption/replacement and both credentials, without mounting or touching a block device.

`omarchy-mac-kernel` replaces the unshipped value-returning `omarchy-hw-apple-kernel`. It queries the target's installed package database, accepts exactly one of `linux-asahi` and `linux-aurora`, and refuses missing, ambiguous or unreadable results. It does not trust an image-written marker, stale module directories or the builder host's `uname`. This identifies the installed kernel family; it does not qualify cross-kernel reset.

The conversion hook now refuses incomplete Limine prerequisites before any GRUB/initramfs rewrite and requires a successful Limine boot update before marking conversion configured. This is an intentional local correction to the pinned conversion source; it is no longer byte-identical. The recipe literals remain required by the authenticated candidate metadata parser. U-Boot source tags now derive from the literal `pkgver`, and unused duplicate Limine version variables are removed. The explicit cryptsetup dependency is intentional because this boot package owns conversion.

## Required fresh-image marker contract (still blocked)

The excluded `mac-image-finalize` helper and existing-user migration are not imported. No current component writes either `deferred-steps` or `limine.enabled`; the schema-4 assembly guard therefore remains mandatory. The existing image builder must own the complete finalization transaction, with artifact inspection instead of tests manufacturing the expected markers:

| Target path | Required meaning and verification |
| --- | --- |
| `/var/lib/omarchy/mac-first-boot/pending` and `/var/lib/omarchy/mac-first-boot/deferred-steps` | Together these authorize the initrd's fresh-image conversion path. Write them only for a genuinely finalized fresh root with its installed first-boot/deferred activation inputs. Define and verify the steps-file contents against the distilled first-boot implementation; a placeholder touch is not integration. Missing either must fail image qualification. |
| `/var/lib/omarchy/provisioning/pending` | Arm the owner unit with its offline runtime/Node inputs. This is separate from the conversion freshness markers. |
| `/var/lib/omarchy/limine.enabled` | Explicit opt-in for the runtime leaf and boot hooks. Finalization must coordinate it with `/etc/default/limine`, the executable runtime updater, the menu/UKI and the actual ESP loader. Its presence alone does not prove activation. |

Inspect both the shipping root and `@factory`. The sealed factory baseline must not retain fresh-conversion/owner-pending state, including `mac-first-boot/deferred-steps`; preserve the validated Limine boot configuration required by reset. Reset re-arms its own pending markers without manufacturing fresh-image conversion authorization. Test a plain install, requested conversion, second encrypted boot, reset/retry, and missing-marker/prerequisite failures in disposable infrastructure. Do not remove the schema-4 guard until this wiring, the authenticated package closure and the boot artifact checks are complete. Chris's frozen schema-3/plain-GRUB bundle is unaffected.

## Review verification

The review implementation passed `test/all`: the CLI suite and all 298 shell test files. An initial aggregate run passed 296/298; the untouched About and pacman fixtures inherited `NO_COLOR` and `LC_ALL` values incompatible with their assertions. Both passed with those variables unset, then the full aggregate passed with `OMARCHY_PATH` set to this checkout, `TERM=xterm-256color`, compositor variables unset and Git signing disabled only for fixture commits. No unrelated test was changed.

Package verification passed the expanded offline boot-source suite, 92 self-tests, 16 candidate ownership checks and 13 candidate signing checks. The builder's 31 signed-input fixtures passed, including the retained schema-4 guard. Disposable signing keys used disk-backed temporary storage. The real LUKS2 regular-file check passed; it uses reduced-cost PBKDF2 fixture parameters and is not a performance or production boot qualification.

The updated recovery retry notice still needs visual inspection on an awake desktop/Apple VT: this session's monitor was disabled and capture requests stalled. Temporary preview and capture processes were stopped. The earlier screenshot verifies the prior screen only. This limitation, retained logs/digests and exact tested implementation commits are recorded in the verification ledger. Later documentation-only commits intentionally leave implementation pins unchanged.
