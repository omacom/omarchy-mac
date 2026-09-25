# Apple Silicon static-media candidate 2026-08-27-a9c09d7b

Status: static structure and complete isolated build verified; physical boot,
installation, reproducible bytes, and release remain unverified

This directory belongs to the active `omarchy-mx-mac` project. It records the
first Apple Silicon ISO accepted by the format-aware verifier in the dedicated
`phase3-arm-build` AArch64 Lima VM. The historical `omarchy-mac` fork was not a
source, synchronization target, or release authority.

## Bound identities

- ISO source and verifier fix:
  `0c1dbd071cd271c62b7d45dfbaa777eaaf6742c1`
- accepted ARM64 base: `b5d562f` / `v4.0.1.m.1`
- ArchISO submodule:
  `424e78130db2af6c1ceb55b442d7914b1109ff2b`
- build image digest:
  `sha256:1245992a2b371b5aeeede7dae44937ab29dc446e9e77abe263b99b02e5c1813d`
- embedded `SOURCE_DATE_EPOCH`: `1787832096` (`2026-08-27T12:01:36Z`)
- distributed filename:
  `omarchy-2026.08.27-aarch64-apple-silicon-quattro.iso`
- ISO size: 3,414,591,488 bytes
- ISO SHA-256:
  `a9c09d7bc510e16275b4721f5e854bae8ade9b392f0a86ad4d3790bf152ffb8f`
- `static-media-evidence.json` SHA-256:
  `8d3431bd6384f29a964823695855c0d2d7a15a39243f9b38bcaa9c3ccc851a5c`
- `build-environment.txt` SHA-256:
  `58aa682678e2c82a73a34712ffd6d85edf245c782743bcd589eb84c8cf55ea6e`

The 3.2 GiB ISO remains only in the dedicated local build VM and is not tracked
or published. The tracked JSON, environment manifest, and complete build log
were copied from the exact accepted candidate. The JSON's artifact filename is
the builder's pre-wrapper name; its SHA-256 and byte size bind the renamed
distributed artifact exactly.

## Gate result

The full isolated build exited zero and the format-aware `lsinitcpio` check
proved that the concatenated initramfs contains the Asahi runtime hook. Static
layout passes. Boot remains explicitly false with blocker
`disposable-asahi-boot-evidence-absent`.

The earlier candidates are retained in the build VM for comparison. Their ISO
bytes differ from this candidate. Analysis localized the differences to
generated host identity/key/cache content and archive timestamps while the
kernel, initramfs, EFI binary, GRUB configuration, package set, and pinned
inputs match. This candidate is therefore not claimed to be byte-reproducible.

This record does not authorize or claim a physical boot, media write,
installation, M4 support, signing, publication, channel change, push, merge,
or existing-user integration.
