# M1 Pro fresh-install checkpoint (0.6.0)

Observed on 2026-08-29 after the owner completed the 1TR Finish Installation
flow, booted Omarchy successfully, and returned to macOS.

This is physical-install evidence for the preserved 0.6.0 OS payload. It is
not release qualification or publication authorization.

## Bound input

- Device: `apple,j314s` (MacBookPro18,3)
- Engine: `v0.9.0-omarchy.6`
- Engine digest: `sha256:25edb28ceb79241f08a4c110639f2d53ae37a02ec77c4c3a89ae2fa94186a7ec`
- Plan digest: `3c5072d77ee11af55dda8d255fa3788852c67c1bc48cc1ccccf759046736e13b`
- Binding digest: `sha256:32ee09eca6cc15ca46641f0f07272db3ca2dd40a0360443da8e89941b44e6f76`
- Payload digest: `sha256:cd651bf7a610d2280084a9c1f28d0a39ac7791ef97e7725fd0627adce3ae1418`
- Metadata digest: `sha256:34fc87e269bece044c19d9e8f5bb1cf495f2c35541e373d6308c604e9adc58ba`
- Install extent: offset `857747943424`, length `137438953472`

## Result

- Stage one reached the bound `awaiting_recovery` checkpoint at journal
  sequence 10.
- The owner completed the 1TR flow and reported a successful Omarchy boot and
  setup.
- Post-install macOS inspection found a new Omarchy volume-group UUID
  `48A51312-3828-43A3-952F-20DCBABD0CB9`, paired and BAA-certified with
  permissive security.
- The existing macOS volume-group UUID
  `3EE75828-1F54-4365-9BA7-E7217E81D869` remained paired and BAA-certified
  with full security.
- The prior Omarchy volume-group UUID
  `EF0906B0-56C5-4FFC-8FB0-8690209333E4` was absent.
- The new Stub, EFI, Boot, and Root partition UUIDs differ from the previous
  installation, proving a fresh layout rather than reuse or merge.
- The original Recovery partition UUID
  `E1BE34A1-D1B8-4F79-BD30-BB50603FD230` remained present.

The journal and its three checkpoint evidence records are preserved beside
this file. `post-install-macos-state.txt` records the small read-only disk and
boot-policy snapshot. Large OS images are intentionally not copied or hashed
again.
