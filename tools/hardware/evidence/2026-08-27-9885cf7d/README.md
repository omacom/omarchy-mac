# Apple Silicon static-media candidate 2026-08-27-9885cf7d

Status: static structure verified; physical boot, installation, and release
unverified

This directory belongs to the active `omarchy-mx-mac` project. It records the
first validation-only Apple Silicon ISO produced from the accepted
`omarchy-iso` ARM64 base. The historical `omarchy-mac` fork was not a source,
synchronization target, or release authority.

## Bound identities

- ISO build source:
  `cb26f81dbe66b4bf9b31f564f334ba0287a3a164`
- static-layout verifier source:
  `50d97710347d82e61b420658d23173c210c46d60`
- deterministic rebuild source:
  `387d899551ce8209fe8ee0e96288879801ece31b`
- accepted base: `b5d562f` / `v4.0.1.m.1`
- ArchISO submodule:
  `424e78130db2af6c1ceb55b442d7914b1109ff2b`
- build image digest:
  `sha256:1245992a2b371b5aeeede7dae44937ab29dc446e9e77abe263b99b02e5c1813d`
- embedded `SOURCE_DATE_EPOCH`: `1787832096` (`2026-08-27T12:01:36Z`)
- ISO: `omarchy-2026.08.27-aarch64.iso`
- ISO size: 3,414,587,392 bytes
- ISO SHA-256:
  `9885cf7df10b251e51b74ac4621a131d966bb1ac7c69bb062b16dedf5042ebda`
- `static-media-evidence.json` SHA-256:
  `ededd9f28735dbaf642f718ab35bf95c727ff2515ce7fcb7398841e96da98799`

The 3.2 GiB ISO remains only in the dedicated local build VM and is not tracked
or published. `static-media-evidence.json` is canonical JSON generated from and
revalidated against those exact ISO bytes and the pinned Apple platform
snapshot.

## Gate result

Static structure passes. Boot remains explicitly false with blocker
`disposable-asahi-boot-evidence-absent`. This record does not authorize or
claim a physical boot, media write, installation, M4 support, signing,
publication, channel change, push, merge, or existing-user integration.
