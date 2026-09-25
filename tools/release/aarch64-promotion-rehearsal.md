# aarch64 promotion rehearsal (edge → rc)

Status: work in progress. Findings so far come from reading omacom/omarchy-pkgs master (`cd1ffe0f`) and read-only copies of the live channel databases; the sandbox run of the advance and the rollback test are still to do. Nothing was published, advanced or edited on omacom/omarchy-pkgs.

## Live state (pulled 2026-09-26 00:16 AEST)

| Slot | Entries | sha256 (first 16) |
| --- | --- | --- |
| edge/x86_64 | — | `840099652ba152ae` |
| edge/aarch64 | 148 | `6c0d62adcb3fbe50` |
| rc/x86_64 | — | `9c90ec59f4467be2` |
| rc/aarch64 | 24 | `3fd1b36fd39a7798` |
| stable/x86_64 | — | `cfca19891c2b8bbf` |
| stable/aarch64 | 22 | `bc5ef35de1a1a75d` |

The Mac set on edge/aarch64: `linux-aurora` and `linux-aurora-headers` 7.1.12.aurora2-10, `m1n1-aurora` 1.6.1.aurora1-3, `uboot-asahi` 2026.07.asahi2-4, `omarchy-mac` 0.1.0-5, `omarchy-mac-boot` 20260925-2, `limine-mkinitcpio-hook` 1.39.0-2, `aquamarine` 0.15.1-1.1.

rc/aarch64 and stable/aarch64 hold only fast-ring packages published by CI, plus the stale `linux-aurora` and `linux-aurora-headers` 7.1.12.aurora2-9 in rc, which still provide `linux=7.1.12.aurora2`.

## Findings

1. **The host's tree does not hold CI-published packages.** `publish.yml` runs `bin/publish-artifact` on an ephemeral droplet (`ci/README.md`), inside a container, in a `mktemp` directory: it pulls the channel database from R2, adds the packages and uploads straight to R2. Nothing writes to the host's `pkgs.omarchy.org/` tree, and the host publishes only `PUBLISHED_ARCHES=x86_64`. `advance-channel` reads `$REPO_ROOT/edge/aarch64/omarchy.db.tar.zst` and copies local files, then `update-repo` rebuilds rc's database from local files only and `sync-repo` uploads it. So on the host the advance either stops at "Source database not found", or its sync refuses because R2's rc/aarch64 lists names the local tree lacks. A local tree holding older files under the same names is worse: the name-only check passes and the rebuilt database would downgrade them. To check on the host, read-only: `ls -la /root/omarchy-pkgs/pkgs.omarchy.org/{edge,rc,stable}/aarch64/` and compare `bsdtar -tf omarchy.db.tar.zst` there with the live databases.
2. **Widening.** `channels: ["edge"]` today: `linux-aurora`, `m1n1-aurora`, `uboot-asahi`, `omarchy-mac`, `omarchy-mac-boot`, `aquamarine`. `limine-mkinitcpio-hook` has no `channels` key (member of every channel); an advance scoped to `--arch aarch64` leaves rc/x86_64 at 1.38.0-1.1. The widening merge publishes nothing (publish.yml finds master's version already on edge), but the widening pull request's required `result` check fails: build-pr builds nothing and `pack_packages` stops with "no *.pkg.tar.zst" (same failure on run 36127895034).
3. **rc/aarch64 cannot install the set alone.** Resolving against rc/aarch64 plus asahi-alarm and ALARM, in the Apple Silicon repository order, leaves `omarchy` and `limine-snapper-sync` unresolved. The closure needs `omarchy`, `omarchy-settings`, `omarchy-keyring`, `ttf-jetbrains-mono-nerd-basic` and `limine-snapper-sync` too. `omarchy` and `omarchy-settings` are `pinned`, so `advance` never carries them; rc/aarch64 needs a native rc build of the pair.
4. **Stale linux-aurora -9.** It must leave rc/aarch64 before or with the promotion, and must not come back through a rollback or a re-hydrated tree.

## Draft plan

1. Owner: remove `linux-aurora` and `linux-aurora-headers` -9 from rc/aarch64.
2. Widening pull request on omarchy-pkgs: add `rc` to `channels` of the six packages above.
3. Host: hydrate `edge/aarch64` (database, set files and signatures) and all of `rc/aarch64` from R2 into a fresh local tree.
4. `bin/repo advance --from edge --to rc --arch aarch64 --package linux-aurora m1n1-aurora uboot-asahi omarchy-mac omarchy-mac-boot limine-mkinitcpio-hook aquamarine --skip-prod-check`, dry run first, through `mac-release`.
5. Check rc/aarch64 serves the set and all three x86_64 databases hash as before.

Rollback: restore the rc/aarch64 database pair saved just before the advance, remove the copied files from the host's tree, and narrow the channels back.

## Still to do

- Sandbox run of the real `advance-channel`, and of `mac-release` against the sandbox, on copies of the live databases; hash the x86_64 databases before and after.
- Run the rollback in the sandbox and verify rc/aarch64 returns to its saved entries.
- Exact widening diff and removal commands; final wording.
