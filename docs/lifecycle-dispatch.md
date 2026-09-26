# Lifecycle dispatch

Omarchy owns the boot lifecycle flows: the owner wizard, account creation, LUKS discovery, retry journals, snapshots and the update flow. Some platforms boot through a chain those flows can't drive generically. Apple Silicon Macs boot m1n1 → U-Boot → Limine, keep the install key on an ext4 boot partition and name it on the kernel command line. For those platforms, the flows call a small fixed set of operations through `bin/omarchy-lifecycle-dispatch`, and a platform boot package implements them as root-owned entrypoints. Every other platform keeps the generic path, and each dispatch call is a no-op there.

## The command

```
omarchy-lifecycle-dispatch <operation> [arguments...]
omarchy-lifecycle-dispatch --resolve <operation>
```

The first form runs the operation. `--resolve` prints the entrypoint the operation would run, or nothing when the operation is a no-op on this machine. A caller uses it when a platform implementation replaces a generic step (see [Callers](#callers)).

| Situation | Run | `--resolve` |
| --- | --- | --- |
| The platform registers no boot package (`generic`, `generic-aarch64`, and `qualcomm` today) | no-op, exit 0 | prints nothing, exit 0 |
| The entrypoint exists and passes the trust rules | execs it; its exit status is the result | prints its path |
| A required operation has no entrypoint, and the package is not installed | exit 3 (an entrypoint's own status could also be 3; with `--resolve` it is only this): `Error: <operation> on <platform> needs <package>, which provides <path>; it is not installed` | same error |
| A required operation has no entrypoint, but the package is installed (its pacman record says so) | exit 1: `Error: <operation> on <platform> needs <path>, which <package> <version> does not provide; update <package>` | same error |
| An optional operation has no entrypoint | no-op, exit 0 | prints nothing, exit 0 |
| The entrypoint fails the trust rules | exit 1: `Error: refusing <path>: ...` (optional operations too) | same error |
| `omarchy-hw-platform` can't settle the platform | exit 1 | exit 1 |
| No operation, or one outside the fixed set | exit 2 with usage | exit 2 |

## Operations

The set is fixed in the dispatcher; adding one is a change to Omarchy. The `provision-*` operations take no arguments and work on fixed paths: `/var/lib/omarchy/provisioning` holds the staged install key (`luks-key`) and the re-key journal (`luks-rekey.state`). `luks-slots` takes the slot numbers it records. Factory reset names the factory root it is about to activate, since that is not `/` yet, and hands `reset-commit` the throwaway key on standard input, never in arguments.

| Operation | Called | Contract | Apple | Caller |
| --- | --- | --- | --- | --- |
| `provision-prepare` | Owner provisioning, at the start of every setup attempt, before the owner is asked anything | Succeeds when the platform can finish setup on this machine. On failure its stderr is shown on tty1 and logged, and the attempt fails into the usual retry screen. It must leave nothing a retry can't repeat. | required | `omarchy-provision-owner` |
| `provision-commit` | Owner provisioning, during the LUKS re-key: after the owner's key is added, before any other slot is retired | Removes every boot-time copy of the staged key and its unlock configuration from the platform's boot chain, and rebuilds the boot files so the next boot asks for the password. Idempotent. If it fails, it leaves or restores a boot chain that still unlocks unattended with the staged key, so the retry boots. | required | `omarchy-provision-owner` |
| `provision-verify` | Owner provisioning, whenever it asks whether the staged unlock remains: before the re-key, during it, and before setup drops `pending` | Read-only. Exits 0 only when the boot chain holds no staged key or unlock configuration. Any other status counts as "remains", so setup never finishes. | required | `omarchy-provision-owner` |
| `reset-prepare <factory-root> [<luks-device>]` | Factory reset, once the factory root is cloned and scrubbed, before switching to it. The device is there only when the root is encrypted. | Stages the platform's boot state for the factory root: the unlock's command line, the rebuilt boot files, and encryption state reopened for the next owner. It keeps what `reset-rollback` restores, and writes no key. | required | `omarchy-system-factory-reset` |
| `reset-verify <factory-root>` | Factory reset, right after `reset-prepare` and before the throwaway slot is added and the switch committed | Read-only. Proves the rebuilt boot files boot the factory root on this boot chain. A failure rolls the reset back. | required | `omarchy-system-factory-reset` |
| `reset-commit` (key on standard input) | Factory reset, once the factory root is the active root | Puts the throwaway key where the staged unlock reads it, so the first boot unlocks unattended until owner setup re-keys, and drops what `reset-rollback` would restore. A failure is logged, not fatal: that boot asks for the current disk password once. | required | `omarchy-system-factory-reset` |
| `reset-rollback` | Factory reset, when anything fails after `reset-prepare` started and before the factory root is active, `reset-prepare`'s own failure included | Restores the previous boot state. Nothing to restore is a success. | required | `omarchy-system-factory-reset` |
| `update-preflight` | Update, before the keyring and package transaction | Refuses an update the platform can't boot afterwards. A failure stops the update. | optional | `omarchy-update-boot preflight` (`omarchy update`) |
| `update-verify` | Update, after the last package step: the transaction, migrations, orphan removal and AUR packages | Read-only. Verifies the boot chain boots the updated system, whose new kernel may still wait for its reboot. A failure leaves the update unfinished: it exits non-zero and offers no reboot. | required | `omarchy-update-boot verify` (`omarchy update`) |
| `boot-rebuild` | Owner provisioning, when a factory reset left boot entries for another machine identity | Rebuilds the platform's boot files, after Omarchy has started the Limine menu over where there is one | optional | `omarchy-provision-owner` |
| `luks-slots` | Owner provisioning, once the re-key keeps only the owner's slot and the acknowledged recovery slot, before it destroys the staged key; the disk password change, once the owner's new key is confirmed | `luks-slots owner=<slot> [recovery=<slot>]` records the root volume's kept slots wherever the platform's boot checks look for them. Without `recovery=` the recorded recovery slot stays; an empty one records none. Idempotent. It fails when a slot is not in the LUKS header, and the caller then retries. A platform that implements it also has owner provisioning create a recovery passphrase (see [Recovery passphrase](#recovery-passphrase)). | required | `omarchy-provision-owner`, `omarchy-drive-password` |

Snapshot restore is not an operation: a Limine machine restores through `limine-snapper-restore`, and a platform boot package that checks a restore does so through limine-snapper-sync's own hooks.

## Platform registration

Registration is code in `bin/omarchy-lifecycle-dispatch`, not configuration. No file, environment variable or `PATH` entry decides what runs as root.

| Platform | Implementation directory | Package | Required operations |
| --- | --- | --- | --- |
| `apple-silicon` | `/usr/lib/omarchy/mac-boot` | `omarchy-mac-boot` | all except `update-preflight` and `boot-rebuild` |
| `generic`, `generic-aarch64`, `qualcomm` | none | none | none: every operation is a no-op, and callers keep their generic path |

The entrypoint for an operation is `<implementation directory>/<operation>`. A registered platform's required operations must be shipped. Its optional operations may be left out, and then they are no-ops.

On a Mac, owner provisioning and factory reset have no other path, so their operations are required: a Mac without `omarchy-mac-boot`'s entrypoints stops before the owner form or before the reset is confirmed, with the dispatcher's error naming the package, where the generic Limine path would leave the boot-partition key behind or rebuild a UKI the Mac does not boot. `luks-slots` is required because the Mac's boot checks prove the owner's and the recovery slot. `update-verify` is required because nothing else checks what an update left in a Mac's boot chain. `boot-rebuild` stays optional until a platform ships it: without it, the stale-entry refresh runs `limine-update`.

## Trust rules

- The dispatcher runs as `bash -p`, so a root caller's `BASH_ENV` and exported functions run nothing in it, and it refuses an ordinary Bash launch. As root it uses a fixed `PATH`, runs the detector installed beside it with nothing in its environment but that `PATH` (the detector reads only the live device tree as root), and resolves only the fixed implementation directory.
- An entrypoint runs only if it is a regular executable file. Neither the file nor any directory up to `/` may be a symlink, and all of them must be owned by root and not writable by group or others. An entrypoint that fails these rules is refused, even for an optional operation.
- The entrypoint runs with an empty environment apart from `PATH=/usr/local/sbin:/usr/local/bin:/usr/bin`. It gets the caller's arguments, standard streams and working directory. Entrypoints use fixed paths, never environment variables. Anything that can also run them directly re-checks the platform itself.
- For unprivileged tests, `OMARCHY_LIFECYCLE_ROOT` (absolute) prefixes the implementation directory, and the detector's fixture roots apply. Inside that root, files the caller owns count as root's. Root ignores both.

## Callers

A dispatch point takes one of two shapes:

- **A platform step with no generic counterpart:** `omarchy-lifecycle-dispatch <operation> || fail`. It is a no-op on platforms without a boot package.
- **A platform implementation that replaces a generic step:** `--resolve <operation>`. A path means dispatch the operation, an empty result means run the generic step, and a failure fails closed.

Failing closed holds on every platform: where `omarchy-hw-platform` can't settle the platform (contradicting device-tree evidence, for one), first-boot setup and factory reset stop instead of guessing a boot path, and an update stops at its preflight.

### Owner provisioning (`bin/omarchy-provision-owner`)

- `platform_ready` runs `provision-prepare` and resolves `luks-slots` at the start of each setup attempt, before the keyboard and account forms. If either fails, the owner sees its error, the log records it, and the attempt ends in the retry or root-shell screen.
- The shared re-key (`install/provisioning/luks-rekey.sh`) asks the caller for two callbacks: `luks_auto_unlock_present` and `luks_auto_unlock_drop`. `unlock_owner` resolves `provision-commit` and `provision-verify` once per process. If both resolve, the platform owns the unlock: drop is `provision-commit`, and present is `provision-verify` failing. If neither resolves, the Limine UKI callbacks run unchanged (x86, Snapdragon, generic aarch64). If only one resolves, or resolution fails, the unlock counts as present and can't be dropped, so setup never finishes.
- After a factory reset left Limine entries for another machine identity, `refresh_boot_entries` starts the menu over from the template, then runs `boot-rebuild` if the platform implements it, and `limine-update` otherwise.
- Where `luks-slots` resolves, `run_setup` creates the recovery passphrase before the worker starts (see [Recovery passphrase](#recovery-passphrase)). The shared re-key calls the caller's `luks_record_slots` once it has verified the kept slots and before it destroys the staged key; `omarchy-provision-owner` runs `luks-slots owner=<slot> recovery=<slot or empty>` there, a no-op where nothing records them.
- Everything else stays as it is: the wizard, account and login, the journal, slot retirement, the proof that the staged key opens nothing, and cleanup.

### Factory reset (`bin/omarchy-system-factory-reset`)

- `reset_boot_owner` resolves the four reset operations before the reset is confirmed. If all resolve, the platform owns the factory root's boot chain; if none do, the generic path runs unchanged (x86, Snapdragon, generic aarch64: throwaway slot, keyfile in the Limine UKI, `limine-update`, `verify_limine_hashes`). If only some resolve, or resolution fails (a Mac without `omarchy-mac-boot`'s entrypoints), the reset stops before anything changes.
- Where the platform owns it, the order is: authorise with the current passphrase and stage the throwaway in the factory root's `/var/lib/omarchy/provisioning/luks-key`; `reset-prepare`; `reset-verify`; add the throwaway slot; switch the subvolumes; `reset-commit` with the throwaway on standard input. The slot comes after verification, so a failed rebuild adds no credential, and the platform writes its boot-time key only after the switch, so a power loss before it leaves the previous root asking for its password, never unlocked unattended.
- Any failure before the switch runs `reset-rollback` (once `reset-prepare` started), then revokes the slot this attempt added (found by the throwaway key when the add was not confirmed) and deletes the clone: the previous root stays the one that boots, with its boot files and encryption state. Operation output goes to the reset log; a failure shows the operation's last line.
- Everything else stays as it is: the @factory clone, identity and account scrub, provisioning markers and units, LUKS discovery, the passphrase check, the throwaway slot, and the subvolume switch.

### Update (`bin/omarchy-update`)

- `omarchy-update-boot preflight` runs after the dev checkout update and before the keyring and system packages change. A refusal stops the update like any failed step.
- `omarchy-update-boot verify` runs after AUR packages, the last sudo-capable step, and before the post-update hook and mise. When it fails, the update still runs those and releases Stay Awake, then says the update is not finished and exits 1 without the reboot prompt.
- `omarchy-update-boot` resolves the operation as the user first and runs it with `sudo` only when it resolves to an entrypoint, so an update with nothing to run never asks for root. A failed resolution fails the step with the dispatcher's message, except one: `update-verify` on a machine without its platform's boot package at all (exit 3) warns that the boot files were not verified and lets the update finish. Such a machine predates the package and boots a chain it does not manage; once the package is installed, a failed verification blocks. A package too old to ship `update-verify` blocks, since the fix is one package update away.
- The update path rebuilds no boot file itself: package hooks do, and `update-verify` catches what they missed.

### Disk password change (`bin/omarchy-drive-password`)

- After the system disk's key changed and the login and root passwords follow it, `record_owner_slot` resolves `luks-slots` as the user and, when it resolves, runs `sudo omarchy-lifecycle-dispatch luks-slots owner=<slot>`, so no other platform sees an extra `sudo`. Until that succeeds the journal stays, and the next run finishes the change and records the slot. The new key can land in another slot (cryptsetup 2.8's `luksChangeKey` moves a LUKS1 key to the first free slot, and keeps a LUKS2 one in place), and the boot check would then find a slot the platform did not record.
- The recovery key stays as it is: the system disk refuses it as the current password, and a new password in its form.

## Recovery passphrase

The recovery passphrase is core code (`install/provisioning/luks-recovery.sh`); whether setup creates one is the platform boot package's call. A boot package that implements `luks-slots` records a recovery slot for its boot checks, so owner provisioning gives it one to record. Every other platform keeps today's first boot: the owner's password alone, no extra screen. Leaving the decision to the boot package keeps the platform check out of the owner wizard, and turning it on elsewhere is a matter of that platform recording the slots.

- **Order:** `prepare_luks_recovery` runs in the foreground before the worker, on every attempt while the staged key file exists. It reserves a free slot in the journal (`recovery_slot`), adds a new 48-character base32 key there with the staged install key, checks the key opens that slot, records `recovery_shown=0`, shows it, and records `recovery_shown=1` once the owner types the acknowledgement. The key is never written to disk or passed as an argument.
- **Interruption:** an acknowledged key is kept. A key added but not acknowledged is removed and replaced in the same slot, and the owner is told to replace any copy they wrote down when it may have been on screen (`recovery_shown=0`). The worker, which retires every slot but the owner's and the acknowledged recovery slot, starts only after the acknowledgement.
- **The owner's password:** the owner's slot is the re-key's own step, so a retry may still choose a new password while the staged key opens the disk, even after the boot step: the re-key then retires the old password's slot and records the final slots with `luks-slots`. The recovery key is refused as the password.
- **Temporary key:** setup finishes only after the re-key proved the staged key opens nothing, the boot package's `provision-verify` found no boot-time copy, and `luks-slots` recorded the kept slots.

## Apple Silicon

`omarchy-mac-boot`, from omacom/omarchy-mac, implements the Apple operations as small entrypoints around its boot modules and installs them in `/usr/lib/omarchy/mac-boot`. Its documentation describes each one. Nothing Apple-specific lives in Omarchy beyond the registration above.

## Qualcomm

Snapdragon laptops boot Limine with unified kernel images, like x86, and `qualcomm` is unregistered. Every operation is a no-op there, and provisioning uses the Limine UKI callbacks, so Dragon behaves exactly as before. To plug in a Qualcomm implementation:

1. Ship the entrypoints from a Qualcomm boot package as `/usr/lib/omarchy/<name>/<operation>`, root-owned, mode 755. `<name>` is a short directory name, as `mac-boot` is for `omarchy-mac-boot`.
2. Add a `qualcomm)` case to the registration in `bin/omarchy-lifecycle-dispatch` with that directory, the package name, and the operations it requires.
3. Operations it neither requires nor ships stay no-ops. For provisioning, ship `provision-commit` and `provision-verify` together, or neither to keep the Limine UKI path.
4. Move `qualcomm` in `test/shell.d/lifecycle-dispatch-test.sh` from the no-op platforms to its own cases, like Apple's.

## Tests

- `test/shell.d/lifecycle-dispatch-test.sh` covers the dispatcher on every platform fixture:
  - no-ops on x86, generic aarch64 and Qualcomm, even with Mac entrypoints on disk
  - Apple with and without the boot package, and with one too old to ship an operation
  - arguments, exit status and the cleared environment
  - untrusted entrypoints
  - usage errors, and an undetermined platform
  - an ordinary Bash launch, and root ignoring fixture roots, `BASH_ENV` and exported functions
- `test/shell.d/luks-rekey-journal-test.sh` runs owner provisioning through the real dispatcher:
  - the crash-and-resume matrix on x86 (Limine UKI path unchanged, no Mac entrypoint runs, no recovery key) and on Apple with a fake boot package (recovery key, recorded slots), on a slot-table fake and on file-backed LUKS2 and LUKS1 volumes
  - setup stopping before the owner form when the boot package is not ready, missing, or too old to ship the provisioning entrypoints
  - the stale-entry refresh rebuilding through `limine-update` on x86 and the boot package on Apple, and through `limine-update` on a boot package without `boot-rebuild`
  - the worker failing closed without the provisioning entrypoints, or when a boot package implements only one of `provision-commit` and `provision-verify`
- `test/shell.d/luks-recovery-test.sh` covers the recovery passphrase on its own.
- `test/shell.d/factory-reset-dispatch-test.sh` runs the reset through the real dispatcher: on x86 with Mac entrypoints on disk that must not run (generic path unchanged), and on Apple into a fake boot package, covering a finished reset, a failed verification and a failed switch that roll back, an unconfirmed throwaway slot found by its key and revoked, a failed commit after the switch, and a missing or partial package.
- `test/shell.d/update-boot-verify-test.sh` runs `omarchy update` through the real `omarchy-update-boot` and dispatcher inside the sudo boundary fixture: no-ops and no root on x86, generic aarch64 and Qualcomm; on Apple, preflight before the keyring, verify after AUR and before the hook, a refused preflight, a failed verification that offers no reboot, and a Mac without the package or with one too old.
- `test/shell.d/drive-password-test.sh` checks that an Apple password change records the owner's new slot through `luks-slots`, including after an interruption, and that x86 never calls it.
