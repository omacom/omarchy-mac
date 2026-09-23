# Private Mac image VM qualification

This harness authenticates a combined schema-4 candidate, its dependency snapshot and its final Limine OS package before booting disposable aarch64 KVM guests. It is a test-only adaptation of Marcelo's `test/vm/mac-image/run` from the recorded source ceiling `d418ab7f95e8ba447df4fb368ddd838a5ffc7943`; cached upstream script SHA256 is `9a76c3542638b53039561ae39e53ba5b93b3789262c8686894d95fb97e48ced6`. The underlying first-boot/conversion harness was introduced in PR 194 at `e2b1076b0c6d8c01b7cb93cfa3d3dc05442e1d39`. The unauthenticated payload and mutable download selectors from that harness are intentionally absent.

The prepared lanes cover an explicit plain installation, explicit requested in-place encryption, and a second encrypted boot. Each requires real guest EFI runtime and the installed Limine runtime to be selected. They inspect the persisted state, owner-pending marker, unique package keyring, loader bytes, staged-key permissions and encrypted Limine command line. They stop before interactive owner completion. A passing run does not qualify owner password/recovery, factory reset or package updates; those require separate guest scenarios. The initial preparation has passed admission tests, syntax checks and an actual Btrfs reflink isolation check; no combined candidate has yet booted through this harness.

The Apple kernel stays installed in the image and remains the kernel used to regenerate the shipping UKI. QEMU directly launches a separately authenticated generic `linux-aarch64` kernel through AAVMF, with an initramfs built using the admitted image's own conversion and encryption hooks. Only the disposable root receives an explicit Apple-detector override and a VM evidence unit; their purpose is to exercise Apple runtime paths on generic hardware. This cannot qualify m1n1, U-Boot, Limine's loading of an Apple UKI, Apple firmware, the GPU or physical hardware. The native Limine code and generated loader/menu are exercised, but QEMU does not boot the Apple UKI.

## Inputs and admission

A caller must supply `--inputs-sha256` independently of the descriptor. The descriptor has exactly these fields:

```json
{
  "schema": 1,
  "kind": "quattro-private-vm-inputs",
  "builder_revision": "40-hex committed private builder revision",
  "runtime_revision": "40-hex packaged runtime revision",
  "trust_policy_sha256": "64-hex",
  "trust_public_sha256": "64-hex",
  "candidate_receipt_sha256": "64-hex",
  "dependency_manifest_sha256": "64-hex",
  "image_verification_sha256": "64-hex",
  "product_sha256": "64-hex",
  "generic_kernel": {
    "filename": "linux-aarch64-7.2.4-1-aarch64.pkg.tar.xz",
    "sha256": "64-hex",
    "signature_sha256": "64-hex",
    "size_bytes": 67598872,
    "version": "7.2.4-1"
  }
}
```

Admission copies verifier and trust files directly from the pinned builder commit, ignoring dirty working-tree files. The normal candidate and dependency verifiers authenticate exclusive local snapshots with the builder's committed development public key; they never install that key into host or guest trust. The descriptor binds the final product and image verification record. The ZIP's size/hash and every image member's size/hash must match that record, unsafe or duplicate members fail, and extracted zero ranges stay sparse. Before building a generic initramfs, the admitted image's embedded candidate and dependency records must match the authenticated snapshots. Its ALARM public keyring verifies the separately pinned generic kernel signature, and `.PKGINFO` must identify the exact admitted kernel version.

Use `admit.py` by itself for admission without root, loop devices or a guest. A destination is always new; incomplete snapshots cannot be reused. It accepts the same admission arguments shown after `--` below and requires `--output NEW-DIRECTORY`.

`--members-source EXPORTED-TREE` optionally admits already exported `root.img`, `boot.img` and ESP/branding members with Linux FICLONE. The ZIP is still fully hashed and its directory checked; every cloned member is independently hashed before use. Linked members and non-CoW/cross-filesystem fallback are refused. Source exports are unchanged. This avoids allocating another copy of sparse image data on the same Btrfs filesystem.

## Run

The host needs aarch64 KVM. The supplied Dockerfile builds disposable QEMU tools from a pinned Ubuntu image. It records package versions at `/tool-packages.txt`; record the resulting immutable image ID and use that ID for execution. No host package installation is needed. The VM itself has no network device.

```bash
test/vm/mac-image/run \
  --state /disk-backed/new-vm-work \
  --evidence /disk-backed/new-vm-evidence \
  -- \
  --inputs /path/VM-INPUTS.json --inputs-sha256 CALLER_PINNED_SHA256 \
  --builder /tmp/quattro-limine-private-builder \
  --candidate-root /path/signed-candidate \
  --dependency-root /path/signed-dependencies \
  --payload /path/package.zip --product /path/product.json \
  --verification /path/image-verification.json \
  --generic-kernel /path/linux-aarch64-7.2.4-1-aarch64.pkg.tar.xz \
  --generic-kernel-signature /path/linux-aarch64-7.2.4-1-aarch64.pkg.tar.xz.sig \
  --members-source /path/exported-members
```

Run that command inside the tools container with read-only mounts for the harness, inputs and builder plus its Git common directory, and separate writable mounts for the new state and evidence parents. The container requires KVM, loop devices and mount/chroot privileges. Do not mount a physical disk or unrelated directories read-write. Neither the harness nor its cleanup discovers disks by UUID: every host loop device is tracked from a new file. Guest UUID lookups happen only inside the guest.

By default, lanes run sequentially and each passing guest disk is removed before the next is created. `--only plain` or `--only encrypted` selects a lane; `--keep` retains successful guest disks and requires more space. Failure state and evidence are retained. A Root partition is the shipped extent plus 256 MiB to exercise expansion. Before allocating a disk, the harness requires free space for its entire virtual capacity plus 1 GiB; a 16 GiB root, 1 GiB Boot and 500 MiB ESP require approximately 18.75 GiB free after admission. This conservatively allows every sparse byte to be written. Encryption initially operates on the measured filesystem extent, but the space check does not depend on that optimization. Disk virtual and allocated sizes are recorded after each lane.

## Validation

```bash
bash test/shell.d/mac-image-vm-admission-test.sh
```

The focused suite covers descriptor substitution, duplicate JSON keys, dirty-verifier substitution, kernel path traversal, immutable snapshot destinations, altered ZIPs, member size/hash mismatches, unexpected/duplicate/symlink/traversing ZIP entries, sparse extraction, wrong boot profile and exported-member substitution. VM execution remains dependent on the authenticated final image and adequate disk space.

## This qualification's launch helper

`launch_private.py` fixes the approved artifact, VM state, evidence, candidate/dependency and kernel paths for the 2026-09-22 private qualification. It pins the disposable tools image by immutable ID. Docker receives only read-only input mounts plus the dedicated `vm/` evidence/state parent read-write; signing-key directories and unrelated workspaces are absent. The host udev database and host PID 1's mount table are exposed read-only so every tracked loop and partition can be checked before mounting. The temporary host rule must already cover the literal backing paths. No launch action installs a rule or changes host automount settings.

Actual audit/VM launch additionally requires `/run/udev/rules.d/99-omarchy-private-limine-20260922.rules` to be a regular file, not a symbolic link, matching the reviewed v3 SHA256 `52f6603520f1c28ff0805d2a1157abed4391c6b19c44b01c39f8a4331676b054`. Missing or changed rule bytes stop execution before any container or loop is created. The host rule must be explicitly reinstalled, reloaded and probed after cleanup; matching a file alone does not prove that udev loaded it, so the existing per-device exclusion/tag checks remain mandatory. `--print-command` does not create devices and leaves this execution-only rule check to the eventual launch.

Once the parent exports `artifact-image-3` and supplies the descriptor hash, run the audit first:

```bash
python3 test/vm/mac-image/launch_private.py audit \
  --inputs /path/VM-INPUTS.json --inputs-sha256 CALLER_PINNED_SHA256
```

The audit authenticates the descriptor-bound image report and exported root bytes, checks the reviewed trust-audit tool's SHA256, then attaches only `payload/root.img` through a read-only loop. It requires the exact backing identity, `UDISKS_IGNORE=1`, this task's private tag and no host mount before mounting `@` and `@factory` with `ro,rescue=nologreplay`. Both shipping trees are checked by the parent-provided audit tool. Cleanup unmounts before detaching, refuses to detach a reused device, and hashes root.img again to prove unchanged bytes. No final VM state directory is created by this audit. Its report is `vm/shipping-trust-audit-image-3.json`.

After that report passes and storage is ready, run both VM lanes:

```bash
python3 test/vm/mac-image/launch_private.py vm \
  --inputs /path/VM-INPUTS.json --inputs-sha256 CALLER_PINNED_SHA256
```

`--print-command` makes either invocation reviewable without starting a container. The VM helper requires the same descriptor to have passed the shipping trust audit. It refuses existing attempt directories and requires more than 19 GiB free both before and after authenticated admission. It uses `vm/state-attempt-1` and `vm/run-attempt-1`; sequential passing disks are removed to preserve space. The generic kernel signature is still verified against the admitted image's ALARM public keyring before its kernel or guest scripts execute. A successful generic boot remains separate from Apple firmware/hardware qualification.

The focused suite additionally covers loop identity substitution, physical-device refusal, missing host exclusion/tag, missing host mount visibility, unexpected desktop mounts, partition-specific exclusion, read-only audit options, partial mount failures and refused cleanup of a reused loop device.

The private launcher supplies a dedicated 3 GiB `/admission-tmp` tmpfs for signed-input verification. Both standard verifiers execute unchanged from the pinned builder commit. Their authenticated temporary snapshots are then materialized as exclusive FICLONE copies of the original read-only input files on the evidence filesystem. Each clone's size/hash must equal its already verified tmpfs counterpart; a source substitution after verification fails. Unsupported CoW never falls back to a large disk copy. The tmpfs staging tree is fully removed before image admission finishes and before the generic build or guest starts, freeing its memory. This preserves signature/manifest checks while avoiding approximately 1.9 GiB of duplicate archive allocation. Direct `admit.py` use keeps normal disk snapshots unless `--snapshot-tmpfs` is supplied explicitly.
