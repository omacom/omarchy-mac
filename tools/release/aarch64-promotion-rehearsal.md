# aarch64 promotion rehearsal: edge → rc

Rehearsed on 2026-09-26 (AEST) against copies of the live channel databases. Nothing was published, advanced or edited on omacom/omarchy-pkgs: the live steps were read-only dry runs over HTTPS, and every real command ran against a sandbox remote.

## Outcome

- `bin/repo advance` cannot promote the Mac set, because the repository host's tree never receives what CI publishes. The fix is an R2-native promotion in omarchy-pkgs: `bin/promote-artifact` and a `promote.yml` dispatch (omacom/omarchy-pkgs#642, draft). It reuses `bin/publish-artifact`, so a promotion is written the same way, by the same writer, as a merge.
- In the sandbox, the set reaches rc/aarch64 with edge's sha256 for every entry. The other 22 rc/aarch64 entries and the other five databases stay unchanged, x86_64 byte for byte. The rollback returns rc/aarch64 to its pre-promotion entries.
- The widening pull request's required build check fails today on a metadata-only change. The same omarchy-pkgs pull request skips the build for those changes.
- rc/aarch64 cannot install the Mac set without the `omarchy` pair and three generic packages. The three move with the set. The pair is pinned, so no promotion carries it: it needs an aarch64 rc build (see below).

## Live state (2026-09-26 00:16 AEST)

| Slot | Entries | Database sha256 |
| --- | --- | --- |
| edge/x86_64 | — | `840099652ba152aeda8f84d93cb111b74dc6e1f3becb077cee23f12e0a120b2c` |
| edge/aarch64 | 148 | `6c0d62adcb3fbe50261e6e58a084ce07362fc6a18b3b7a1fcef1c7aee33294d6` |
| rc/x86_64 | — | `9c90ec59f4467be229028f32f951035e2dad972d3647c55231a51755af26e157` |
| rc/aarch64 | 24 | `3fd1b36fd39a77984fdc07777ebd48cc77485933c849410806fb632c7bc5c660` |
| stable/x86_64 | — | `cfca19891c2b8bbfce8ffa8ee1861b969fceb4b685d75cb312151ced4cdc8939` |
| stable/aarch64 | 22 | `bc5ef35de1a1a75dc5aa57b7b5e49ca519ec12758e47d6ec906730d2b86887ba` |

rc/aarch64 and stable/aarch64 hold only fast-ring packages that CI published, plus, in rc, the stale `linux-aurora` and `linux-aurora-headers` 7.1.12.aurora2-9, which still provide `linux=7.1.12.aurora2`.

## Why the host path fails

This settles the question ticket 30 left open. `publish.yml` runs `bin/publish-artifact` on an ephemeral CI droplet (`ci/README.md`), inside the builder container, in a `mktemp` directory: it pulls the channel database from R2, adds the packages and uploads straight back to R2. Nothing is written to the host's `pkgs.omarchy.org/` tree, and the host publishes only `PUBLISHED_ARCHES`, `x86_64` by default (the host's own setting is still to confirm), so it holds no aarch64 channel of its own either.

`advance-channel` reads `$REPO_ROOT/edge/aarch64/omarchy.db.tar.zst` and copies local files. `update-repo` then rebuilds the target database from the local tree alone, and `sync-repo` uploads it. On the host that either stops at "Source database not found", or the sync refuses because R2's rc/aarch64 lists names the local tree lacks. A local tree with older files under the same names is worse: the name-only check passes and the rebuilt database silently downgrades them. The host was not reachable from here. To confirm read-only on it: `ls -la /root/omarchy-pkgs/pkgs.omarchy.org/{edge,rc,stable}/aarch64/`, and compare `bsdtar -tf omarchy.db.tar.zst` there with the table above.

## The fix: promote on the remote

| Option | Verdict |
| --- | --- |
| Hydrate the host's tree from R2, then `bin/repo advance` | No code, but the host becomes a second writer to rc/aarch64, which CI's fast ring also publishes into. The database is rebuilt from the hydrated tree and the sync checks names only, so a CI publication that lands in between is silently reverted |
| Make `publish.yml` copy its files to the host too | Puts host SSH credentials in CI, still misses everything published before, and keeps two writers |
| **Promote on the remote through `bin/publish-artifact`** | One writer (CI's `publish` environment and concurrency group), files and databases only in R2, no new signing or upload code |

`bin/promote-artifact --from edge --to rc --arch aarch64 --package <names...> [--expect-sha256 <digest>] [--dry-run]`:

1. reads the source database on the remote and takes each named package's entry (split packages by pkgbase);
2. refuses a package that may not move into the target, using `package_moves_to_channel`, the rule `advance-channel` uses. A package that is not a member needs widening. A pinned or fast-ring one is built natively in rc;
3. with `--expect-sha256`, refuses unless those entries hash to the qualified set. The digest is the one `mac-release` computes, `sha256` of the sorted `name version filename sha256` lines: for the same packages both printed `6d4bda8e…`;
4. refuses to move a package backwards or over other bytes of the same version;
5. downloads the files, checks each against the source database's `%SHA256SUM%`, and publishes them with `bin/publish-artifact --mirror rc --arch aarch64`. It then checks the target holds exactly its earlier entries with the set's replaced or added, and prints the commands that undo it.

`--withdraw --to <channel> --arch <arch> --package <names...>` removes entries from a channel's database with `repo-remove` and uploads the database. `--reinstate --to <channel> --arch <arch> --file <filenames...>` publishes a file the channel still holds back into its database, over a newer entry. Files are never deleted, since published filenames are immutable. Withdraw removes the stale -9. Together the two undo any promotion.

`promote.yml` runs all three modes by `workflow_dispatch` in the `publish` environment and concurrency group, with `dry_run` on by default. GitHub keeps one pending run per concurrency group and cancels an older pending one, which is how the publishes of #626 and #631 were lost. So a preflight job refuses while any publish is running or queued. The same pull request makes `bin/publish-artifact` stop on an unreadable channel instead of starting a new database, which would have dropped every entry.

## Widening

Six recipes have `channels: ["edge"]` and need `rc`: `linux-aurora`, `m1n1-aurora`, `uboot-asahi`, `omarchy-mac`, `omarchy-mac-boot`, `aquamarine`. `mac-release` writes the diff (`jq` on `.omarchy/package.json`, six files, 28 insertions and 6 deletions). `limine-mkinitcpio-hook` and the three closure packages have no `channels` key and are already members of every channel. Promoting them with `--arch aarch64` leaves rc/x86_64 on `limine-mkinitcpio-hook` 1.38.0-1.1 and `limine-snapper-sync` 1.31.0-1.1.

Merging the widening publishes nothing: `publish.yml` finds master's version already on edge and records it as already published. Its required check fails today, though. `build-pr.yml` runs `bin/build`, which builds nothing because the version is published, and `pack_packages` stops on "no *.pkg.tar.zst" (the same failure as run 36127895034 on a settings PR). The omarchy-pkgs pull request leaves a package out of the PR build matrix when three things hold: `.omarchy/package.json` is the only file of it that changed, the recipe has no `pkgver()`, and edge already serves master's version. makepkg reads nothing from that file. Simulated against the widening diff and the live edge databases, the six widened recipes skip, while a pkgrel bump or an unpublished version still builds. The widening pull request does not carry this change, so it has to be on master before that pull request is opened or its checks are run again.

## rc/aarch64 can't install the set alone

Resolved against rc/aarch64, asahi-alarm and ALARM in the Apple Silicon repository order (`default/pacman/apple-silicon/pacman-rc.conf`), the set leaves `omarchy` and `limine-snapper-sync` unresolved. The full closure needs five more packages: `limine-snapper-sync`, `omarchy-keyring`, `ttf-jetbrains-mono-nerd-basic`, `omarchy` and `omarchy-settings`. The first three move with the set. With the promoted sandbox database plus the pair, nothing is unresolved.

The pair (`omarchy`, `omarchy-settings`) is `pinned`. rc builds it natively from the `rc` branch (`OMARCHY_RC_PINS`), so neither `advance` nor `promote-artifact` moves it into rc (the dry run refuses it as "built natively for rc"). That rc build runs on the host for `PUBLISHED_ARCHES` only, so it has never run for aarch64. edge/aarch64 carries a stale 4.0.2-1 while master and `rc` pin 4.0.4-1. Two steps, neither built here:

1. Bring edge/aarch64 to master's pin with the existing path: `gh workflow run publish.yml -R omacom/omarchy-pkgs -f packages="omarchy omarchy-settings"`. It builds and publishes what is not published yet, so aarch64 only.
2. Build the rc pin for aarch64 in CI. One way: a `promote.yml` job that overlays `rc`'s `pkgbuilds/omarchy{,-settings}`, runs `OMARCHY_RC_PINS=1 bin/build --mirror rc --arch aarch64`, and publishes with `bin/publish-artifact --mirror rc --arch aarch64`. The narrower one: `promote-artifact` accepts a pinned package into rc when its source version equals the `rc` branch's pin, which keeps the rule's purpose (master never overwrites an in-flight RC). Until one of them lands, the Mac set in rc/aarch64 is installable only on a machine that already has `omarchy`.

## Stale linux-aurora -9

Withdraw it: `promote-artifact --withdraw --to rc --arch aarch64 --package linux-aurora` (the pkgbase takes the headers too). Do not use `bin/repo remove` on the host. Dropping a name needs `sync --prune`, which deletes every remote file missing from the host's tree, and that includes all of CI's rc/aarch64 files.

## The plan

The owner runs these steps. Every change goes through a dry run first.

1. Merge omacom/omarchy-pkgs#642 (`promote-artifact`, `promote.yml`, the metadata-only build check).
2. Withdraw the stale kernel: `gh workflow run promote.yml -R omacom/omarchy-pkgs -f action=withdraw -f to=rc -f arch=aarch64 -f packages=linux-aurora`, read the log, then again with `-f dry_run=false`.
3. The pair on aarch64, as above.
4. Qualify: VM acceptance and M1 Pro and M2 Max cold boots of the set. `mac-release --dry-run --to rc` with the ten `--package` names below prints the digest and the exact `boot=` lines. On 2026-09-26 the digest was `6d4bda8e56f35780feaf135546ac799f31c224871c33490d67ad9713295c8e3b`, 11 entries.
5. Widen: `mac-release` opens the pull request; merge it, which publishes nothing.
6. Promote: `gh workflow run promote.yml -R omacom/omarchy-pkgs -f from=edge -f to=rc -f arch=aarch64 -f packages="linux-aurora m1n1-aurora uboot-asahi omarchy-mac omarchy-mac-boot limine-mkinitcpio-hook aquamarine limine-snapper-sync omarchy-keyring ttf-jetbrains-mono-nerd-basic" -f expect_sha256=<digest>`, read the dry run, then again with `-f dry_run=false`.
7. Check: rc/aarch64 serves the 11 entries with edge's sha256, and the three x86_64 databases hash as before.

## Rehearsal

`tools/release/test/aarch64-promotion-rehearsal <omarchy-pkgs checkout>` repeats it, in an Arch container (its header has the `docker run` line). The run on 2026-09-26 against master `cd1ffe0f` plus the prototype:

- A1, live dry run: the withdrawal names `linux-aurora` and `linux-aurora-headers` 7.1.12.aurora2-9.
- A2, live dry run before widening: refuses the six non-members ("not a member of rc; widen its channels first").
- A3, live dry run after widening: 11 entries, set digest `6d4bda8e…`, two moves from -9 to -10 and nine new names, and "only rc/aarch64 would change".
- A4: `omarchy` and `omarchy-settings` are refused as built natively for rc.
- B, sandbox, a local remote seeded with the six live databases (the hashes above, byte for byte) and the 11 real files from edge/aarch64, signing with a throwaway key: the withdrawal takes rc/aarch64 from 24 entries to 22, and the promotion (`--expect-sha256` from A3) to 33. Every earlier entry is kept, each promoted entry carries edge's sha256, and the x86_64 databases stay byte-identical, with only rc/aarch64 changed. Running the promotion again is a no-op. The rollback withdraws the 11 and returns rc/aarch64 to exactly the 22 earlier entries, with x86_64 still byte-identical.

`tests/promote-artifact.sh` in omarchy-pkgs covers the same paths on fixtures and runs in its CI. It checks the refusals (non-member, pinned, same version with other bytes, wrong digest, bad name), a real replacement of an older split package, signatures, that the other databases stay byte-identical, the no-op re-run, backwards moves, the full rollback (withdraw what was added, reinstate what was replaced), and the URL dry run and its failure path.

## Rollback

- Run the commands the promotion printed. Withdraw what it added (`action=withdraw` with those names). Reinstate what it replaced (`action=reinstate` with the earlier filenames, which are still in the slot). Once -9 is withdrawn, this promotion replaces nothing, so its rollback is the withdrawal of the 11 names. Both are tested, in the rehearsal and in `tests/promote-artifact.sh`. The files stay in R2 and nothing references them.
- Revert the widening pull request, so the next promotion cannot carry the set by accident. After the build check fix, that revert is metadata-only as well.
- Macs that already updated keep what they installed: pacman does not downgrade on `-Syu`, and a withdrawn package just becomes foreign. A bad package, a boot package above all, is fixed forward: a new pkgrel on edge, qualified and promoted again.

## Follow-ups

- `mac-release` still plans `bin/repo advance` on the host. Once omarchy-pkgs#642 lands, its advance step should dispatch `promote.yml` with `--expect-sha256` set to its set digest, then keep its existing after-checks. That drops `OMARCHY_REPO_HOST` and the host dry-run comparison.
- The aarch64 rc build of the pinned pair (above).
- `publish.yml` loses merges: GitHub keeps one pending run per concurrency group, so the publishes of #370, #451, #598, #626 and #631 were cancelled while waiting. A promotion that holds the group widens the window, and a publish can still start between `promote.yml`'s preflight and its job. After each promotion, check that no publish run was cancelled, and dispatch `publish.yml` again for any that was. The fix belongs to omarchy-pkgs, a queue that never cancels.
- The host/R2 split also affects the x86_64 `advance` for anything CI publishes. Upstream's `ci/README.md` still lists "disable the host's auto-release timers for any channel CI publishes to" as not done.
- stable later goes the same way: `--from rc --to stable`. The pair moves rc → stable under the current rule.
