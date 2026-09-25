# M1 canary sequence 2004 checkpoint

This directory preserves the post-run state of the explicitly non-release M1
canary. Sequence 2004 reused the qualified 0.6.0 payload and the existing
four-partition Omarchy layout. It rewrote only Boot and Root; Stub and EFI were
preserved.

Observed physical result:

- Omarchy completed its local setup and reached an installed system.
- Boot exhaustive read-back: `sha256:6a3b0a54f9f588d615a96510fb3f5a33a14897ac9a7ea6026792f877d9a7a7f9`.
- Root exhaustive read-back: `sha256:395a3db964c58733dd2e820baa04e3b3a0ed39025c3240867e431bdd3af7a8b7`.
- The engine journal recorded `existing-install-validated`,
  `repair-content-written`, and `repair_readback_validation_started`. The
  controller session ended before `repair-content-validated` was appended, so
  this is physical canary evidence, not a completed release transcript.
- After returning to macOS, Macintosh HD was the selected boot volume and its
  policy remained `full`. The separate Omarchy volume-group policy remained
  `permissive` and properly paired.
- `disk0s7`, the Apple APFS Recovery partition, remained present and unchanged
  by the repair operation.

Artifacts:

- `sequence-2004-state.tar.gz` is the root-owned canary state copied from
  `/var/db/omarchy-canary`; SHA-256
  `bfe1e461dae4745255e82cf281786a2cd554a9c0846ff5a400a6404e46ea88e5`.
- `post-canary-macos-state.txt` is the read-only post-boot system, policy, disk,
  and APFS-volume-group inventory; SHA-256
  `a6486acf4e4a394427eff2dd07d55b3c156adb32d544daa038b6a35d2a5b79c8`.

Do not treat this checkpoint as clean-install proof. It proves the in-place
repair path over an existing Asahi/Omarchy stub, EFI partition, and boot policy.
