# Mac release tooling

The commands that take a Mac change to installed Macs. They orchestrate; the package repositories sign, publish and advance channels with their own interfaces. Two lanes:

- **omacom** (the default): Mac packages in omacom/omarchy-pkgs, promoted edge → rc → stable by widening channel membership and a scoped `aarch64` advance. This is where Apple Silicon releases converge.
- **fork**: the frozen omarchy-mx-mac lane on maralcbr/omarchy-pkgs `asahi-quattro`, for security and boot fixes until mx-mac is archived. It is omarchy-pkgs `bin/asahi-release` and `bin/mac-aurora-pin`, moved here.

| Path | What it is |
| --- | --- |
| `mac-release` | The release command. `--lane fork` runs `fork/asahi-release` |
| `mac-aurora-pin` | Moves the Aurora kernel pin; on omacom also promotes it |
| `fork/asahi-release` | The fork lane's release engine (was omarchy-pkgs `bin/asahi-release`) |
| `fork/asahi-repository-signing.asc` | The fork repository's public key, the trust anchor for its candidates |
| `lib/omacom.sh` | Reading omacom recipes and channel databases, pins, pull requests |
| `test/omacom-lane` | The omacom lane against a fake repository, databases and `gh` |
| `test/fork-parity` | The fork's own suites run against the relocated fork lane |

All commands need bash 5; on macOS run them with `/opt/homebrew/bin/bash`. None needs an omarchy-pkgs or omarchy-mx-mac checkout: they clone what they read.

## The omacom lane

```bash
tools/release/mac-release --dry-run [--to rc|stable] [--package NAME]... [OMARCHY_MAC_COMMIT]
tools/release/mac-release [--to rc|stable] [--vm-evidence FILE] [--hardware-evidence FILE] [OMARCHY_MAC_COMMIT]
```

The set is every Apple package (`omarchy-mac`, `omarchy-mac-boot`, `linux-aurora`, `m1n1-aurora`, `uboot-asahi`) unless `--package` narrows it. There is no state: each run reads master, the channel databases and the pull requests, takes the next step and stops. Run the same command again to continue.

1. **Pin.** With a commit of omacom/omarchy-mac `quattro-upstream`, a pull request moves `_commit` of the recipes built from it (`omarchy-mac`, `omarchy-mac-boot`) and bumps `pkgrel`. A pin never moves backwards. The owner merges it; CI's `publish.yml` then builds, signs and publishes with `bin/publish-artifact` to the channels `bin/build-matrix` gives each package (edge, for a Mac recipe).
2. **Wait** until the source channel (edge for `--to rc`, rc for `--to stable`) serves master's version of every package in the set.
3. **Gates.** The set's identity is its **set digest**: the SHA-256 of the sorted `name version filename sha256` lines of the set in the source channel's database. Published filenames are immutable on omacom, so the digest pins exact bytes. Nothing is promoted without a VM acceptance record naming it, and a promotion that moves a boot package (kernels, m1n1, U-Boot, `omarchy-mac-boot`, `limine-mkinitcpio-hook`, DKMS) also needs a hardware record naming exactly those moves. The dry run prints the lines each record must hold.
4. **Widen.** A pull request adds the target channel to `.omarchy/package.json` `channels` of the packages that are not members yet. Membership is what `bin/repo advance` checks; the merge publishes nothing new, since master's version is already on edge.
5. **Advance.** `bin/repo advance --from <source> --to <target> --arch aarch64 --package <moved packages> --skip-prod-check`, forwarded by omacom's own `bin/repo` to the build host named in `OMARCHY_REPO_HOST`. It copies files and their signatures; it never builds. Because `advance-channel` takes package names and copies what the host's tree holds, the command first reads the source channel again (it must still hold the qualified digest) and runs the same advance with `--dry-run` on the host: it must copy exactly the qualified files, find already present only what the target already serves, and withhold nothing as differing or ineligible. A host tree that already holds a move the target does not serve (an advance whose sync failed) stops for the operator, with the `bin/repo sync` to run. Afterwards the command checks the target serves the set and that no `x86_64` database changed.

Evidence records are plain text; free text is allowed, and these lines must be there exactly:

```text
# --vm-evidence
format=1
set_sha256=<set digest>
status=accepted

# --hardware-evidence: cold boots on the M1 Pro and the M2 Max
set_sha256=<set digest>
boot=<package> <version>      # one per moved boot package, no more and no fewer
```

Settings come from `KEY=value` lines in `$MAC_RELEASE_CONFIG` (else `$ASAHI_RELEASE_CONFIG`, else `~/.config/omarchy/mac-release.conf`) or the environment: `MAC_RELEASE_AUTHOR_NAME` and `MAC_RELEASE_AUTHOR_EMAIL` author the pull requests. The fork lane's `ASAHI_RELEASE_*` keys are read too, so one file serves both lanes. `MAC_RELEASE_PKGS_GIT`, `MAC_RELEASE_SOURCE_GIT` and `MAC_RELEASE_DB_BASE` point the lane elsewhere (the tests use them).

## Aurora on omacom

omacom has one recipe, `pkgbuilds/linux-aurora`; channels do what the fork's `linux-aurora-edge`, `-rc` and `-stable` recipes did.

```bash
tools/release/mac-aurora-pin pin [--branch aurora-wip] [--archive-sha256 SHA] [--dry-run]
tools/release/mac-aurora-pin promote rc|stable [--vm-evidence FILE] [--hardware-evidence FILE] [--dry-run]
```

`pin` moves the recipe to the head of an aurora-silicon/linux branch: `_commit`, the first `sha256sums` entry (the `github.com/.../archive/<sha>.tar.gz` archive the recipe sources, never `gh api`'s tarball) and a new version (`_auroraver` from the source Makefile with `pkgrel=1`, or `pkgrel + 1`). It refuses a pin that would lower the version, since pacman never installs an older kernel over a newer one. The result is a pull request; merging it publishes the kernel to edge. `promote` is `mac-release --package linux-aurora --package m1n1-aurora --to rc|stable`: the kernel reaches rc and stable only as the edge build that was cold-booted, never as a rebuild.

## The fork lane

The one release command of the mx-mac runbook (`docs/apple-silicon-deployment.md`), now run from this repository instead of a fresh `origin/asahi-quattro` worktree of omarchy-pkgs:

```bash
ASAHI_RELEASE_CONFIG=~/omarchy-lab/asahi-release.conf /opt/homebrew/bin/bash tools/release/mac-release --lane fork --dry-run <mx-mac commit>
ASAHI_RELEASE_CONFIG=~/omarchy-lab/asahi-release.conf /opt/homebrew/bin/bash tools/release/mac-release --lane fork [--update-macs] [--hardware-evidence FILE] <mx-mac commit>
tools/release/mac-aurora-pin --lane fork edge|rc|stable [--archive-sha256 SHA] [--recipe DIR] [--dry-run]
```

It decides exactly as before; its options, settings, hard stops and resume are the ones the fork's `docs/asahi-resumable-release.md` describes, with `tools/release/mac-release --lane fork` in place of `bin/asahi-release` (`--runtime-only` replaces `bin/asahi-runtime-release`). What moved:

- It clones both repositories itself. `bin/asahi-candidate-lineage` and `bin/asahi-package-payload` come from the `asahi-quattro` head it resolved, so they are the rules the fork's workflows enforce; `ASAHI_RELEASE_HELPERS` names a directory to take them from instead.
- The fork repository's public key sits next to the engine and is the trust anchor for candidates. When the fork rotates its signing key, update `fork/asahi-repository-signing.asc`.
- State stays in `~/.local/state/omarchy-release`, and the lock is the same file, so a release started with the fork's copy resumes here and the two can never run at once.
- `mac-aurora-pin --lane fork` edits a recipe in place with `--recipe DIR`, as before, but only once every check has passed; with `--dry-run` it prints the change and leaves the recipe alone. Without `--recipe` the tool makes a sparse clone of the fork: `--dry-run` prints the change, and a real run opens a pull request against `asahi-quattro`.

## From the fork lane to omacom

| Fork lane | omacom |
| --- | --- |
| `pkgbuilds/omarchy-source.conf` pin PR, squash-merged by the command | `_commit` pin PR on each Mac recipe, merged by the owner |
| `release-asahi-package-incremental.yml` builds a signed, immutable candidate | CI's `publish.yml` builds, signs (`bin/publish-artifact`) and publishes to edge on merge |
| `CANDIDATE` descriptor digest | Set digest of the source channel's database entries |
| VM acceptance on the VM host, `acceptance.txt` | `--vm-evidence` record naming the set digest |
| `--hardware-evidence` with `candidate_sha256=`, `boot=`, `pin=` | `--hardware-evidence` with `set_sha256=`, `boot=` |
| `promote-asahi-package-candidate`, `publish-asahi-packages-channel.yml`, pointer | Channel widening PR, then `bin/repo advance --arch aarch64 --package ...` |
| Runtime channel `asahi-quattro-channel-<N>` (fast path) | None: `omarchy-mac` is a package, so every change is a package promotion |
| `linux-aurora-edge`, `-rc`, `-stable` recipes and releases | One `linux-aurora` recipe; edge → rc → stable by advance |

## Gaps

Where omacom has no interface yet, the lane stops and says so rather than working around it:

- **Mac recipes.** All five are on omacom master, edge-only (tickets 06–09). A recipe that is missing or fast-ring is still reported as blocked.
- **The host's tree and R2.** `advance-channel` reads the build host's local tree, but `publish.yml` publishes to R2 directly and nothing copies those files back, so the host holds none of the CI-built Mac packages. The fix is `bin/promote-artifact` and `promote.yml` in omacom/omarchy-pkgs#642, rehearsed in [aarch64-promotion-rehearsal.md](aarch64-promotion-rehearsal.md). Until it lands, the advance step here stops at the host's dry run.
- **Advance by name.** `advance-channel` cannot be told which files to copy, only which packages, and its dry run names only the files it copies. A publication to the source channel between the host's dry run and the advance, or a host tree whose unchanged entries differ from what R2 serves, would be carried along; the check afterwards catches it, but only once it is public. Closing that needs an expected-manifest option in `advance-channel`.
- **No scoped advance in `bin/omarchy-release`.** Its `host_advance` always passes `--arch all`, which would move x86_64 channels too, so the lane calls `bin/repo advance` directly with `--arch aarch64 --package`.
- **No signed candidate descriptor.** The set digest over the channel database stands in for the fork's signed `CANDIDATE`. The lane does not verify package signatures itself: `bin/publish-artifact` signs, `advance-channel` refuses a package without its `.sig`, and pacman verifies on install.
- **VM acceptance of an omacom set.** The relocated harness (tickets 27, 28) does not install from omacom channels yet, so the lane takes a record rather than running the VM.
- **Mac updates.** `--update-macs` exists only on the fork lane; on omacom, hardware checks after a promotion belong to the hardware tooling (ticket 29).
- **Rollback.** `advance-channel` only moves forward. `promote-artifact --withdraw` and `--reinstate` undo a promotion; see [aarch64-promotion-rehearsal.md](aarch64-promotion-rehearsal.md).
- **The fork's copies.** `bin/asahi-release` and `bin/mac-aurora-pin` still exist in maralcbr/omarchy-pkgs. The fork is frozen; replace them with a pointer here or leave them until the fork is archived.

## Tests

```bash
tools/release/test/omacom-lane
FORK_PKGS_DIR=<fork checkout> tools/release/test/fork-parity
tools/release/test/aarch64-promotion-rehearsal <omarchy-pkgs checkout>
```

`omacom-lane` runs a whole promotion against a fake omacom repository, fake channel databases and a fake `gh`: pin, gates, widening and a scoped advance. `aarch64-promotion-rehearsal` plans the Mac set's edge → rc promotion against the live repository, then runs it and its rollback against a sandbox copy, in an Arch container (its header has the command). `fork-parity` runs the fork's own `test/asahi-release`, `test/asahi-runtime-release` and `test/aurora-mac-pin` against this directory's fork lane. It needs the fork CI's tools (Ubuntu with `libarchive-tools` and `pacman-package-manager`); the fork's Mac-update scenario does not run on macOS, even against the original.
