# Test candidate sets

A candidate set is the exact package set an Apple Silicon test image is built from: the packages built from one omarchy-mac commit (`omarchy`, `omarchy-settings`, `omarchy-mac`, `omarchy-mac-boot`) plus the kernel, m1n1, U-Boot and Limine hook from their test lanes. Each set has a directory here whose `manifest.json` records every package's source, version, filename and SHA-256, and the set digest (`set_sha256`, computed as in `mac-release`: the sorted `name version filename sha256` lines).

Sets are for test images only, never for installed systems. A set's files sit in a draft release of the owner's `maralcbr/omarchy-pkgs` fork, visible only to its collaborators; no pacman database or channel serves them, and no omacom repository or release holds them. The four omarchy-mac packages are built by the fork's `lab/22-candidate-set` branch (`lab/build`, pinned in `lab/candidate-set.env`); the test-lane packages are omacom/omarchy-pkgs pull request builds. Like any pull request build, those unsigned build artifacts are downloadable from the public Actions runs until they expire (30 days on the fork, 7 on omacom).

## Signing and verifying

Sets are signed by the candidate test lane key, which no Omarchy keyring trusts. The owner signs a set with one command from a checkout of this branch (macOS needs Homebrew bash, jq and gpg):

```bash
/opt/homebrew/bin/bash tools/release/candidate-set sign tools/release/candidates/<set>/manifest.json
```

It downloads the release's packages and checks them against the manifest, creates the key on first use in `~/.local/share/omarchy/candidate-signing` (apart from personal keyrings), writes a detached signature per package and a signed `signing.json` receipt binding the manifest and set digest, verifies the result including a tampered copy, uploads the signatures, receipt and public key to the release, and copies `signing.json` beside the manifest. Commit that receipt: its fingerprint is what consumers trust.

```bash
tools/release/candidate-set verify tools/release/candidates/<set>/manifest.json <fingerprint> [DIR]
```

`verify` trusts only the fingerprint it is given, never the key beside the files, and fails on any changed package, receipt or manifest, a missing signature, or a signature by another key. `tools/release/test/candidate-set` covers these cases with a disposable key.

## Sets

| Set | Source | Contents |
| --- | --- | --- |
| `apple-test-073e489b5b85-20260925` | omarchy-mac `073e489b5b85` (head of #527: #503 with fixes, on #517) | omarchy/omarchy-settings/omarchy-mac/omarchy-mac-boot from that commit; linux-aurora and headers 7.1.12.aurora2-10 (omacom/omarchy-pkgs#625), m1n1-aurora 1.6.1.aurora1-3 and uboot-asahi 2026.07.asahi2-4 (#627), limine-mkinitcpio-hook 1.39.0-2 with the Apple gate (#631) |
| `apple-test-99ace4070354-20260926` | quattro-upstream `99ace4070354` (2026-09-26, after #527 and #528) | omarchy/omarchy-settings/omarchy-mac from that commit; from omacom edge: omarchy-mac-boot 20260925-3 (boot subtree identical to the source commit), linux-aurora and headers 7.1.12.aurora2-10, m1n1-aurora 1.6.1.aurora1-3, uboot-asahi 2026.07.asahi2-4, limine-mkinitcpio-hook 1.39.0-2, and the 35 other packages of the Apple default set's closure that the Apple repository order takes from omacom (44 in all; the rest come from ALARM and asahi-alarm, recorded in the manifest). Signed by `E11E851AF82E02AEF54C8794599A6024E3D35379` |
| `apple-test-b2ba91785ed8-20260926` | quattro-upstream `b2ba91785ed8` (2026-09-26, image 3: after #561, #563, #564, #567–#569, #572–#577) | omarchy/omarchy-settings/omarchy-mac/omarchy-mac-boot from that commit (omarchy-mac-boot 20260926-1.&lt;run&gt;, above edge's 20260925-4, so the runtime and boot package agree on the speakersafetyd owner); from omacom edge: linux-aurora and headers 7.1.12.aurora2-10, m1n1-aurora 1.6.1.aurora1-3, uboot-asahi 2026.07.asahi2-4, limine-mkinitcpio-hook 1.39.0-2, and the 35 other packages of the Apple default set's closure that the Apple repository order takes from omacom (44 in all; vulkan-asahi, asahi-bless and alsa-ucm-conf-asahi come from ALARM and asahi-alarm, recorded in the manifest). Signed by `E11E851AF82E02AEF54C8794599A6024E3D35379` |
| `apple-test-1937418f520b-20260926` | quattro-upstream `1937418f520b` (2026-09-26, image 4: after #539, #578, #579, #581–#591) | omarchy/omarchy-settings/omarchy-mac/omarchy-mac-boot from that commit (omarchy-settings from omacom/omarchy-pkgs#636's recipe, so it ships the platform guard the runtime's first hardware step expects; the boot package's check runs in the full checkout, where #582's legacy migration test finds the settings HOOKS baseline); from omacom edge, unchanged from image 3: linux-aurora and headers 7.1.12.aurora2-10, m1n1-aurora 1.6.1.aurora1-3, uboot-asahi 2026.07.asahi2-4, limine-mkinitcpio-hook 1.39.0-2 and the 35 other packages of the Apple default set's closure that the Apple repository order takes from omacom (44 in all). Signed by `E11E851AF82E02AEF54C8794599A6024E3D35379` |
