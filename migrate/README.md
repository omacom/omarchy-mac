# omarchy-mac-migrate

Moves an Apple Silicon Mac running an Omarchy fork onto Omarchy's official packages for the channel it follows, as one journaled, resumable migration. It is a single self-contained script (`bin/omarchy-mac-migrate`) built from `migrate/src`, and no package carries migration code: omarchy-mac (this repository's `quattro`) and omarchy-mx-mac ship the script, and testers download the release asset.

## What a migrated Mac runs

On edge: `omarchy-dev` and `omarchy-settings-dev` from `https://pkgs.omarchy.org/edge/aarch64`, `omarchy-mac` and `omarchy-mac-boot` (built from omacom/omarchy-mac-pkgs), `linux-aurora`, `m1n1-aurora`, `uboot-asahi` and Limine; `asahi-alarm-keyring` and `omarchy-keyring`. `/etc/pacman.conf` is Omarchy's Apple Silicon configuration (`[omarchy]` first, `[asahi-alarm]`, then Arch Linux ARM), plus the administrator's own options and repositories. No fork package, repository, key or pin is left. On stable and rc the runtime pair is `omarchy` and `omarchy-settings`.

A channel takes Macs once the signed archives its `[omarchy]` would install carry the Mac: the runtime ships `omarchy-lifecycle-dispatch`, and `omarchy-mac-boot` ships its `setup-boot` and `update-verify` operations and no migration engine of its own (that is, it is built from omacom/omarchy-mac-pkgs). Until then every Mac on that channel defers, with nothing changed.

## Who it moves

| Cohort | Told by | Channel |
| --- | --- | --- |
| omarchy-mac quattro (legacy): checkout, guided or channel install | no `omarchy` package, `omarchy-mac-keyring`, or quattro's `omarchy-upgrade-to-quattro-mac` | `[omarchy-aarch64]` lane `…/omarchy-pkgs-aarch64/releases/download/<channel>` |
| Test images and collaboration builds (tester) | `omarchy` installed; or the dev pair with the image builder's pin | `[omarchy-aarch64]` lane, else `[omarchy]` `pkgs.omarchy.org/<channel>` |
| omarchy-mx-mac | `omarchy-dev` with the fork's updaters or records | `omarchy-apple-silicon-channel current` |
| Omarchy's own dev pair | `omarchy-dev` without the above | nothing to migrate |

An administrator's `/etc/omarchy-mac/migration-target` (or `--target FILE`, root-owned) overrides the channel or points at a mirror or a signed candidate set. A channel that cannot be told defers.

## How it runs

`status`, `check` (preflight only), `run`, `verify` (the boot unit's). Exit 0: migrated, waiting for its reboot, or nothing to migrate. 75: deferred, nothing changed. Anything else: a step failed after the repository switch; the next run, or the next boot, resumes it.

Steps, each journaled in `/var/lib/omarchy-mac/migration/journal`: `preflight` (refusals, channel, isolated resolution against a copy of the package database and keyring, the target's verified archives, its boot tools for the checks; freezes the plan and the sync databases), `backup` (packages, `/etc`, `/boot`, the ESP, the LUKS header), `keyring`, `prefetch` (downloads and rehearses the one transaction on a database copy; refuses any removal the plan does not allow and any file a removed package would take from another), `repositories` (the core configuration with a guard that holds back every package the migration changes; arms the boot unit), `transaction` (one `pacman -Su` from the frozen databases and cache), `boot-chain`, `loader` (the legacy GRUB→Limine stage, then `omarchy-lifecycle-dispatch setup-boot`), `defaults` (default packages, `setup-system`, repairs, settled migrations, user units, `setup-user` per user), `verify` (`update-verify`), `unpin` (drops the guard and a test image's pin), `reboot` (waits; after it, the running Aurora kernel, the packaged Limine, the full boot check and `update-verify`), `retire`.

Before the repository switch a failure sets the attempt aside and defers (the next run starts over); from it on, the migration only goes forward. The tool keeps a copy of itself beside the journal; a migration in progress resumes with that copy unless a newer tool of the same journal format takes over.

## Build and release

```bash
migrate/build          # writes bin/omarchy-mac-migrate and the README one-liner's checksum
migrate/build --check  # CI: both are current
```

Tests: `test/shell.d/mac-migrate-test.sh` (tester cohort, engine), `mac-migrate-legacy-test.sh`, `mac-migrate-mx-test.sh`, `mac-move-migration-test.sh` (delivery). Release: raise `tool_version` in `src/engine.sh` (and `journal_format` only when a journal can no longer be resumed across versions), build, merge, then publish `bin/omarchy-mac-migrate` as the asset of release `mac-migrate-v<tool_version>`. omarchy-mx-mac vendors the same file byte for byte.
