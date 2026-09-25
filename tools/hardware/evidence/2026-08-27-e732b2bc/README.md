# Apple Silicon read-only static candidate 2026-08-27-e732b2bc

Status: static read-only-media controls verified; physical boot, installation,
reproducible bytes, and release remain unverified

This directory belongs to the active `omarchy-mx-mac` project. It records the
first Apple Silicon ISO whose canonical verifier proves that the validation
console is present, automatic disk discovery is disabled, and installer or
disk-mutation entry points are absent. The historical `omarchy-mac` fork was
not a source, synchronization target, or release authority.

## Bound identities

- ISO source and read-only-media controls:
  `dfa58faded2b123ea01dbfadad20d22bdc0bd9fb`
- accepted ARM64 base: `b5d562f` / `v4.0.1.m.1`
- ArchISO submodule:
  `424e78130db2af6c1ceb55b442d7914b1109ff2b`
- build image digest:
  `sha256:1245992a2b371b5aeeede7dae44937ab29dc446e9e77abe263b99b02e5c1813d`
- embedded `SOURCE_DATE_EPOCH`: `1787832096` (`2026-08-27T12:01:36Z`)
- distributed filename:
  `omarchy-2026.08.27-aarch64-apple-silicon-quattro.iso`
- ISO size: 3,414,530,048 bytes
- ISO SHA-256:
  `e732b2bc025e382dcf5c75e43236f06dc1eb6db574a6c9e70a2a308af151b2c7`
- `static-media-evidence.json` SHA-256:
  `4590a462bfb59a63ae742c57eaf7f567207a74ae9e0f8695bf7487f1dc4a0543`
- `build-environment.txt` SHA-256:
  `264d52bc2c3d77a868cd37aec6fe22337dc361d4242e0f759a92a0a69b5c1e93`
- `build.log.gz` SHA-256:
  `d549f15af1458c35e55d68aff9883dd6d94c54d332e0c96ef6e037dbc3188345`
- decompressed build log SHA-256:
  `41ba78273eb4d36da0070aaff4c0ddfd30de059b2dff7c73965bcbd628b3b5c0`

The 3.2 GiB ISO remains only in the dedicated local build VM and is not tracked
or published. The tracked JSON, environment manifest, and losslessly
compressed complete build log were copied byte-for-byte from the accepted VM
archive. The JSON's artifact filename is the builder's pre-wrapper name; its
SHA-256 and byte size bind the renamed distributed artifact exactly.

## Gate result

The full isolated build exited zero. The canonical static verifier proved an
AArch64 EFI image, matching ISO and appended-ESP EFI bytes, `linux-asahi`, the
Asahi initramfs hook, the pinned platform snapshot, and the absence of generic
ARM and Limine artifacts. It also proved the validation console is present,
all installer and disk-mutation entry points are absent, and GRUB passes all
four systemd GPT/fstab automatic-discovery disablement arguments.

At live startup, the validation console is designed to fail closed if an NVMe
device is already mounted read-write, disable NVMe-backed swap, set each NVMe
namespace read-only at the block layer, verify the resulting state, and write
its report only under `/run` before presenting a diagnostic shell.

Candidate `2026-08-27-a9c09d7b` remains useful structural evidence but is not
eligible for physical canary use because its live root still contained and
could launch the normal installer and disk-mutation paths. This candidate
supersedes it for the read-only canary gate.

Boot remains explicitly false with blocker
`disposable-asahi-boot-evidence-absent`. This record does not authorize or
claim a media write, physical boot, installation, M4 support, signing,
publication, channel change, push, merge, or existing-user integration.
