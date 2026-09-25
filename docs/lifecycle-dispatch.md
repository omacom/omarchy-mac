# Lifecycle dispatch

Upstream Omarchy owns the boot lifecycle flows: the owner wizard, account creation, LUKS discovery, retry journals, snapshots, the migration runner and the update flow. Some platforms boot through a chain those flows can't drive generically. Apple Silicon Macs boot m1n1 → U-Boot → GRUB or Limine, keep the install key on an ext4 boot partition and name it on the kernel command line. For those platforms, the flows call a small fixed set of operations through `bin/omarchy-lifecycle-dispatch`, and a platform boot package implements them as root-owned entrypoints. Every other platform keeps the generic path, and each dispatch call is a no-op there.

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

The set is fixed in the dispatcher; adding one is an upstream change. The `provision-*` operations take no arguments and work on fixed paths: `/var/lib/omarchy/provisioning` holds the staged install key (`luks-key`) and the re-key journal (`luks-rekey.state`). `luks-slots` takes the slot numbers it records. Factory reset names the factory root it is about to activate, since that is not `/` yet, and hands `reset-commit` the throwaway key on standard input, never in arguments. The other operations define their arguments when their caller is wired.

| Operation | Called | Contract | Apple | Caller |
| --- | --- | --- | --- | --- |
| `provision-prepare` | Owner provisioning, at the start of every setup attempt, before the owner is asked anything | Succeeds when the platform can finish setup on this machine. On failure its stderr is shown on tty1 and logged, and the attempt fails into the usual retry screen. It must leave nothing a retry can't repeat. | required | `omarchy-provision-owner` |
| `provision-commit` | Owner provisioning, during the LUKS re-key: after the owner's key is added, before any other slot is retired | Removes every boot-time copy of the staged key and its unlock configuration from the platform's boot chain, and rebuilds the boot files so the next boot asks for the password. Idempotent. If it fails, it leaves or restores a boot chain that still unlocks unattended with the staged key, so the retry boots. | required | `omarchy-provision-owner` |
| `provision-verify` | Owner provisioning, whenever it asks whether the staged unlock remains: before the re-key, during it, and before setup drops `pending` | Read-only. Exits 0 only when the boot chain holds no staged key or unlock configuration. Any other status counts as "remains", so setup never finishes. | required | `omarchy-provision-owner` |
| `reset-prepare <factory-root> [<luks-device>]` | Factory reset, once the factory root is cloned and scrubbed, before switching to it. The device is there only when the root is encrypted. | Stages the platform's boot state for the factory root: the unlock's command line, the rebuilt boot files, and encryption state reopened for the next owner. It keeps what `reset-rollback` restores, and writes no key. | required | `omarchy-system-factory-reset` |
| `reset-verify <factory-root>` | Factory reset, right after `reset-prepare` and before the throwaway slot is added and the switch committed | Read-only. Proves the rebuilt boot files boot the factory root on this boot chain: kernel, firmware and device-tree coherence, the unlock on the command line, loader entries and hashes. A failure rolls the reset back. | required | `omarchy-system-factory-reset` |
| `reset-commit` (key on standard input) | Factory reset, once the factory root is the active root | Puts the throwaway key where the staged unlock reads it, so the first boot unlocks unattended until owner setup re-keys, and drops what `reset-rollback` would restore. A failure is logged, not fatal: that boot asks for the current disk password once. | required | `omarchy-system-factory-reset` |
| `reset-rollback` | Factory reset, when anything fails after `reset-prepare` started and before the factory root is active, `reset-prepare`'s own failure included | Restores the previous boot state. Nothing to restore is a success. | required | `omarchy-system-factory-reset` |
| `update-preflight` | Update, before the keyring and package transaction | Refuses an update the platform can't boot afterwards. A failure stops the update. | optional | `omarchy-update-boot preflight` (`omarchy update`) |
| `update-verify` | Update, after the last package step: the transaction, migrations, the post-update hook, AUR, mise and orphans | Read-only. Verifies the boot chain boots the updated system, whose new kernel may still wait for its reboot. A failure leaves the update unfinished: it exits non-zero and offers no reboot. | required | `omarchy-update-boot verify` (`omarchy update`) |
| `boot-rebuild` | Whenever upstream rebuilds boot files: owner provisioning after a factory reset left entries for another machine identity, later kernel and initramfs hooks, snapshots and command-line changes | Rebuilds the platform's boot files, after upstream has started the Limine menu over where there is one | optional until ticket 36, then required | `omarchy-provision-owner`; ticket 36 |
| `luks-slots` | Owner provisioning, once the re-key keeps only the owner's slot and the acknowledged recovery slot, before it destroys the staged key; the disk password change, once the owner's new key is confirmed | `luks-slots owner=<slot> [recovery=<slot>]` records the root volume's kept slots wherever the platform's boot checks look for them. Without `recovery=` the recorded recovery slot stays; an empty one records none. Idempotent. It fails when a slot is not in the LUKS header, and the caller then retries. A platform that implements it also has owner provisioning create a recovery passphrase (see [Recovery passphrase](#recovery-passphrase)). | required | `omarchy-provision-owner`, `omarchy-drive-password` |
| `migrate` | The platform migration (`migrations/1790347292.sh`), on every update until it has run | Moves the machine onto the platform's official package set in place, or does nothing when the platform has no target set yet. Idempotent and resumable: a machine already on the target, or one whose migration waits for a reboot, exits 0. A refusal or failure exits non-zero and leaves the migration pending. | optional | the migration; ticket 42 |

## Platform registration

Registration is code in `bin/omarchy-lifecycle-dispatch`, not configuration. No file, environment variable or `PATH` entry decides what runs as root.

| Platform | Implementation directory | Package | Required operations |
| --- | --- | --- | --- |
| `apple-silicon` | `/usr/lib/omarchy/mac-boot` | `omarchy-mac-boot` | all except `update-preflight` and `boot-rebuild` |
| `generic`, `generic-aarch64`, `qualcomm` | none | none | none: every operation is a no-op, and callers keep their generic path |

The entrypoint for an operation is `<implementation directory>/<operation>`. A registered platform's required operations must be shipped. Its optional operations may be left out, and then they are no-ops.

`omarchy-mac-boot` ships the provisioning entrypoints from 20260925-2 (ticket 32), and owner provisioning has no other Apple path, so they are required: a Mac whose `omarchy-mac-boot` is older stops before the owner form with the dispatcher's error naming the package, where the generic Limine path would leave the boot-partition key and `rd.luks.key=` behind. The reset entrypoints (ticket 34) are required for the same reason: a Mac without them stops before the reset is confirmed, where the generic path would rebuild a Limine UKI the Mac does not boot. `luks-slots` (ticket 33) is required for the same reason: the boot check proves the owner's and the recovery slot, so a Mac whose package cannot record them stops before the owner form too, and `omarchy-drive-password` refuses to change the system disk. `boot-rebuild` stays optional until ticket 36 ships it. `update-verify` is required, and `omarchy update` calls it (ticket 35).

## Trust rules

- The dispatcher runs as `bash -p`, so a root caller's `BASH_ENV` and exported functions run nothing in it. As root it uses a fixed `PATH`, runs the detector installed beside it with nothing in its environment but that `PATH` (the detector reads only the live device tree as root), and resolves only the fixed implementation directory.
- An entrypoint runs only if it is a regular executable file. Neither the file nor any directory up to `/` may be a symlink, and all of them must be owned by root and not writable by group or others. An entrypoint that fails these rules is refused, even for an optional operation.
- The entrypoint runs with an empty environment apart from `PATH=/usr/local/sbin:/usr/local/bin:/usr/bin`. It gets the caller's arguments, standard streams and working directory. Entrypoints use fixed paths, never environment variables. Anything that can also run them directly re-checks the platform itself.
- For unprivileged tests, `OMARCHY_LIFECYCLE_ROOT` (absolute) prefixes the implementation directory, and the detector's fixture roots apply. Files the caller owns count as root's. Root ignores both.

## Callers

A dispatch point takes one of two shapes:

- **A platform step with no generic counterpart:** `omarchy-lifecycle-dispatch <operation> || fail`. It is a no-op on platforms without a boot package.
- **A platform implementation that replaces a generic step:** `--resolve <operation>`. A path means dispatch the operation, an empty result means run the generic step, and a failure fails closed.

### Owner provisioning (`bin/omarchy-provision-owner`)

- `platform_ready` runs `provision-prepare` and resolves `luks-slots` at the start of each setup attempt, before the keyboard and account forms. If either fails, the owner sees its error, the log records it, and the attempt ends in the retry or root-shell screen. On Apple, where both are required, a Mac without `omarchy-mac-boot`'s entrypoints stops here with the dispatcher's error naming the package.
- Apple has no direct path any more (ticket 32): #527's `rekey_luks_apple` runs as the shared re-key with `omarchy-mac-boot`'s entrypoints, and a Mac without them stops at `provision-prepare`.
- The shared re-key (`install/provisioning/luks-rekey.sh`) asks the caller for two callbacks: `luks_auto_unlock_present` and `luks_auto_unlock_drop`. `unlock_owner` resolves `provision-commit` and `provision-verify` once per process. If both resolve, the platform owns the unlock: drop is `provision-commit`, and present is `provision-verify` failing. If neither resolves, the Limine UKI callbacks run unchanged (x86, Snapdragon, generic aarch64). If only one resolves, or resolution fails, the unlock counts as present and can't be dropped, so setup never finishes.
- After a factory reset left Limine entries for another machine identity, `refresh_boot_entries` starts the menu over from the template (core), then runs `boot-rebuild` if the platform implements it, and `limine-update` otherwise.
- Where `luks-slots` resolves, `run_setup` creates the recovery passphrase before the worker starts (see [Recovery passphrase](#recovery-passphrase)). The shared re-key calls the caller's `luks_record_slots` once it has verified the kept slots and before it destroys the staged key; `omarchy-provision-owner` runs `luks-slots owner=<slot> recovery=<slot or empty>` there, a no-op where nothing records them.
- Everything else stays upstream: the wizard, account and login, the journal, slot retirement, the proof that the staged key opens nothing, and cleanup.

### Factory reset (`bin/omarchy-system-factory-reset`)

- `reset_boot_owner` resolves the four reset operations before the reset is confirmed. If all resolve, the platform owns the factory root's boot chain; if none do, the generic path runs unchanged (x86, Snapdragon, generic aarch64: throwaway slot, keyfile in the Limine UKI, `limine-update`, `verify_limine_hashes`). If only some resolve, or resolution fails (Apple without `omarchy-mac-boot`'s entrypoints), the reset stops before anything changes.
- Where the platform owns it, the order is: authorise with the current passphrase (`--token-type passphrase-only`) and stage the throwaway in the factory root's `/var/lib/omarchy/provisioning/luks-key`; `reset-prepare`; `reset-verify`; add the throwaway slot; switch the subvolumes; `reset-commit` with the throwaway on standard input. The slot comes after verification, so a failed rebuild adds no credential, and the platform writes its boot-time key only after the switch, so a power loss before it leaves the previous root asking for its password, never unlocked unattended.
- Any failure before the switch runs `reset-rollback` (once `reset-prepare` started), then revokes the slot this attempt added and deletes the clone: the previous root stays the one that boots, with its boot files and encryption state. Operation output goes to the reset log; a failure shows the operation's last line.
- Everything else stays upstream: the @factory clone, identity and account scrub, provisioning markers and units, LUKS discovery, the passphrase check, the throwaway slot, and the subvolume switch.

### Update (`bin/omarchy-update`)

- `omarchy-update-boot preflight` runs after the dev checkout update and before the keyring and system packages change. A refusal stops the update like any failed step.
- `omarchy-update-boot verify` runs after the last package step. When it fails, the update still checks its log, refreshes the update indicator and releases Stay Awake, then says the update is not finished and exits 1 without `omarchy-update-restart`, so no reboot is offered.
- `omarchy-update-boot` resolves the operation as the user first and runs it with `sudo` only when it resolves to an entrypoint, so an update with nothing to run never asks for root. A failed resolution fails the step with the dispatcher's message, except one: `update-verify` on a machine without its platform's boot package at all (exit 3) warns that the boot files were not verified and lets the update finish. Such a machine predates the package and boots a chain it does not manage; its migration installs the package, and from then on a failed verification blocks. A package too old to ship `update-verify` blocks, since the fix is one package update away.
- The update path rebuilds no boot file itself: package hooks do, and `update-verify` catches what they missed.

### Disk password change (`bin/omarchy-drive-password`)

- After the system disk's key changed and the login and root passwords follow it, `record_owner_slot` resolves `luks-slots` as the user and, when it resolves, runs `sudo omarchy-lifecycle-dispatch luks-slots owner=<slot>`, so no other platform sees an extra `sudo`. Until that succeeds the journal stays, and the next run finishes the change and records the slot. The new key can land in another slot (cryptsetup 2.8's `luksChangeKey` moves a LUKS1 key to the first free slot, and keeps a LUKS2 one in place), and the boot check would then find a slot `encrypt.state` does not name.
- The recovery key stays as it is: the system disk refuses it as the current password, and a new password in its form.

## Apple implementation

`omarchy-mac-boot` implements the Apple operations. #503, landed as #527, moved the Apple boot code into `packages/omarchy-mac/boot/`, with sourced modules in `/usr/lib/omarchy-mac/boot` and commands in `/usr/bin`. Its modules become the implementation with small entrypoints around them (tickets 32, 34 and 35):

| #527 today | Operation | Change |
| --- | --- | --- |
| `omarchy-provision-owner` sources `/usr/lib/omarchy-mac/boot/provision.sh` when `omarchy-hw-apple-silicon` succeeds, and refuses with "Required omarchy-mac-boot provision support is unavailable" | `provision-prepare` | The refusal becomes the dispatcher's required-operation error. The read-only entrypoint (ticket 32) refuses a plain root when the first boot recorded `encrypt=1` (it records that for an absent `install.conf`), an unfinished conversion, a LUKS device `/etc/crypttab` does not name, an initramfs that does not load the vendor firmware before the password prompt, and boot files that do not go to the ESP the device tree names (`omarchy-mac-esp`). A leftover unlock is no longer refused here: the journal commits it away. |
| `apple_rekey_boot` in `lib/provision.sh` (drop `rd.luks.key=` from `/etc/default/grub`, `mkinitcpio -P`, `omarchy-mac-boot-update`), the `/boot/omarchy/luks-key` half of `shred_luks_keyfiles`, then `mark_encrypt_finished` | `provision-commit` | The entrypoint (ticket 32) sources the module, which sets its paths and output, and runs `apple_rekey_boot`, checks that the rebuilt initramfs still loads the vendor firmware before the prompt, then removes the boot-partition key and records `phase=finished` with the journal's owner slot and acknowledged recovery slot. The key goes last, so until then the initramfs still unlocks with it; a failed rebuild restores `rd.luks.key=` and rebuilds with it. It refuses while a conversion is unfinished. |
| The Apple half of `require_finished_luks`, and `run_provisioning`'s refusal before `encrypt.state` reaches `finished` | `provision-verify` | New read-only entrypoint (ticket 32): no `/boot/omarchy/luks-key`, no `rd.luks.key=` in the GRUB defaults or the command line the Mac boots (`/etc/default/limine` on a Limine Mac, `grub.cfg` otherwise), `encrypt.state` absent, `declined` or `finished` |
| `stage_luks_rekey_apple` in `lib/factory-reset.sh`, `reopen_encrypt_state` in `omarchy-system-factory-reset` | `reset-prepare` | Ticket 34: the entrypoint copies the live crypttab and GRUB defaults into the factory root with `rd.luks.key=` for the device's LUKS UUID, and reopens `encrypt.state` last, before the caller adds the throwaway slot. |
| `rebuild_next_boot_apple` (factory-kernel coherence refusal, boot-file backup, Limine menu reset on `/boot/efi`, rebuild in the factory root, `verify_limine_hashes`) | `reset-prepare`, `reset-verify` | Ticket 34: prepare refuses a factory kernel that differs from `/boot`'s, an ESP Limine does not write to, and a failed backup, all before changing anything. It starts the menu over on the ESP `omarchy-mac-esp` names (`/boot/efi` or `/boot`), and rebuilds with the factory root's `omarchy-mac-boot-update` (or `update-grub`). verify checks the kernel again, the initramfs's firmware ordering and the unlock on the GRUB defaults and the loader's command line, and on a Limine factory root the menu's entry for its machine-id with every UKI hash. The firmware check is new: a factory root whose own `omarchy-mac-boot` predates the vendor-firmware ordering can't be reset, where it used to reset into owner setup that `provision-prepare` then refuses. |
| `install_reset_boot_key` and the backup discard in `omarchy-system-factory-reset` | `reset-commit` | Ticket 34: `/boot/omarchy/luks-key` from standard input, mode 600, written durably, for the `rd.luks.key=` that `reset-prepare` staged. |
| `restore_live_boot_files` in `lib/factory-reset.sh`, `restore_encrypt_state` in `omarchy-system-factory-reset` | `reset-rollback` | Ticket 34: the saved boot files and `encrypt.state` come back from `/run/omarchy-mac-boot/reset`; the old Limine menu only if every UKI it names is back with its hash. A partial restore keeps the copies there and fails. |
| `omarchy-mac-boot-update` | `boot-rebuild` | Thin entrypoint around the existing command. Provisioning calls it once shipped; until ticket 36 ships it, Apple refreshes stale entries with `limine-update`, as #527 did. The update path does not call it. |
| `omarchy-apple-silicon-boot-check` | `update-verify` | `entrypoints/update-verify` (ticket 35) runs the check limited to the boot chain (`--boot-chain`), with the new kernel's reboot allowed to be pending: the kernel and initramfs in `/boot`, the device-tree set, m1n1 stage 2 and U-Boot on the system ESP, and Limine's loader, menu and UKI on that same ESP. It holds only the kernel image, device trees and m1n1 against their packages, checks the kernel the boot menu starts first when both kernels are installed, and leaves out LUKS keyslots, provisioning leftovers and an m1n1 image its owner took over with `M1N1_UPDATE_DISABLED`. On failure it says not to reboot and how to rebuild the boot files. |
| The owner and recovery slots `mark_encrypt_finished` wrote into `encrypt.state` once | `luks-slots` | New entrypoint (ticket 33): records `owner_slot` and `recovery_slot` after checking the root's LUKS header (named by `/etc/crypttab`) holds both, keeping `partition=`, `luks_uuid=` and the phase. A Mac whose image was not encrypted (no `encrypt.state`, or `declined`) records nothing. |
| `omarchy-mac-migrate` (ticket 42) | `migrate` | `entrypoints/migrate` runs `omarchy-mac-migrate run` |

- **Packaging:** `packages/omarchy-mac/boot/install` gains one loop that installs `entrypoints/*` as `/usr/lib/omarchy/mac-boot/<operation>`, mode 755. The modules stay where #527 put them and are sourced by absolute path.
- **Owner and recovery slots:** #527's `rekey_luks_apple` sequence is folded into the shared journal. Its owner and recovery slot steps are core (`luks-rekey.sh`, `luks-recovery.sh`): the journal keeps a recovery slot once the owner acknowledged its key and retires every other one. Only its boot step is `provision-commit`, and recording the final slots is `luks-slots`.

## Recovery passphrase

The recovery passphrase is core code; whether setup creates one is the platform boot package's call (ticket 33). A boot package that implements `luks-slots` records a recovery slot for its boot checks, so owner provisioning gives it one to record. `omarchy-mac-boot` implements it, as omarchy-mx-mac gave every Mac a recovery key. Every other platform keeps x86's first boot: the owner's password alone, no extra screen. Moving the decision into the boot package keeps the platform check out of the owner wizard, and turning it on elsewhere is a matter of that platform recording the slots.

- **Order:** `prepare_luks_recovery` runs in the foreground before the worker, on every attempt while the staged key file exists. It reserves a free slot in the journal (`recovery_slot`), adds a new 48-character base32 key there with the staged install key, checks the key opens that slot, records `recovery_shown=0`, shows it, and records `recovery_shown=1` once the owner types the acknowledgement. The key is never written to disk or passed as an argument.
- **Interruption:** an acknowledged key is kept. A key added but not acknowledged is removed and replaced in the same slot, and the owner is told to replace any copy they wrote down when it may have been on screen (`recovery_shown=0`). The worker, which retires every slot but the owner's and the acknowledged recovery slot, starts only after the acknowledgement.
- **The owner's password:** the owner's slot is the re-key's own step, so a retry may still choose a new password while the staged key opens the disk, as on x86, even after the boot step: the re-key then retires the old password's slot and records the final slots with `luks-slots`. The recovery key is refused as the password.
- **Temporary key:** setup finishes only after the re-key proved the staged key opens nothing, the boot package's `provision-verify` found no boot-time copy, and `luks-slots` recorded the kept slots.

## Snapshots

Snapshot restore is not a dispatch operation. A Limine Mac restores through `limine-snapper-restore`, as x86 does: limine-snapper-sync swaps the root and puts the snapshot's saved UKI and menu entry back itself, so nothing is rebuilt afterwards. `omarchy-mac-boot` checks the restore through limine-snapper-sync's own hook interface, the one its Limine activation gate already uses. Its pre hook (`/etc/boot/hooks/pre.d/04-omarchy-mac-snapshot-check`) runs the boot check `update-verify` runs (`--boot-chain`) on the booted snapshot, with no reboot pending, and stops a restore the boot files do not match. Its post hook (`post.d/99-omarchy-mac-snapshot-check`) checks the root the restore put back, which limine-snapper-restore's own list can make a different snapshot, and keeps the reboot from being offered when it does not match. `omarchy-snapshot restore` sends a Mac that still boots GRUB to `omarchy-system-snapshot-restore`, which refuses a Limine Mac and asks `omarchy-mac-snapshot-check` about the chosen snapshot on a GRUB one.

## Qualcomm

Snapdragon laptops boot Limine with unified kernel images, like x86, and `qualcomm` is unregistered. Every operation is a no-op there, and provisioning uses the Limine UKI callbacks, so Dragon behaves exactly as before. To plug in a Qualcomm implementation:

1. Ship the entrypoints from a Qualcomm boot package as `/usr/lib/omarchy/<name>/<operation>`, root-owned, mode 755. `<name>` is a short directory name, as `mac-boot` is for `omarchy-mac-boot`.
2. Add a `qualcomm)` case to the registration in `bin/omarchy-lifecycle-dispatch` with that directory, the package name, and the operations it requires.
3. Operations it neither requires nor ships stay no-ops. For provisioning, ship `provision-commit` and `provision-verify` together, or neither to keep the Limine UKI path.
4. Move `qualcomm` in `test/shell.d/lifecycle-dispatch-test.sh` from the no-op platforms to its own cases, like Apple's.

## Tests

- `test/shell.d/lifecycle-dispatch-test.sh` covers the dispatcher on every platform fixture:
  - no-ops on x86, generic aarch64 and Qualcomm, even with Mac entrypoints on disk
  - Apple with and without the boot package
  - arguments, exit status and the cleared environment
  - untrusted entrypoints
  - usage errors, and an undetermined platform
  - root ignoring fixture roots, `BASH_ENV` and exported functions
- `test/shell.d/update-boot-verify-test.sh` runs `omarchy update` through the real dispatcher: no-ops and no root on x86, generic aarch64 and Qualcomm; on Apple, preflight before the packages, and `omarchy-mac-boot`'s real `update-verify` and boot check on a fixture Mac, where a wrong device tree, a stale m1n1 or a missing UKI fails the update without offering the reboot.
- `test/shell.d/luks-rekey-journal-test.sh` runs owner provisioning through the real dispatcher:
  - the crash-and-resume matrix on x86 (Limine UKI path unchanged, no Mac entrypoint runs) and on Apple with a fake boot package
  - setup stopping before the owner form when the boot package is not ready, missing, or too old to ship the provisioning entrypoints
  - the stale-entry refresh rebuilding through `limine-update` on x86 and the boot package on Apple
  - the worker failing closed without the provisioning entrypoints, or when a boot package implements only one of `provision-commit` and `provision-verify`
- `test/shell.d/provision-owner-luks-test.sh` runs owner provisioning through the dispatcher into `omarchy-mac-boot`'s staged entrypoints, and `packages/omarchy-mac/boot/test/mac-provision-test.sh` covers those entrypoints on their own (ticket 32) and `luks-slots` (ticket 33).
- `test/shell.d/factory-reset-luks-test.sh` runs `stage_full_reset` through the real dispatcher: on x86 with Mac entrypoints on disk that must not run (generic path unchanged), and on Apple into `omarchy-mac-boot`'s staged reset entrypoints, covering a finished reset and a failed verification that rolls back to the previous root. `packages/omarchy-mac/boot/test/mac-reset-test.sh` covers the reset entrypoints on their own (ticket 34).
- `test/shell.d/luks-rekey-journal-test.sh` also runs the Apple setup attempt, recovery step included, killed after every durable step on the slot-table fake and on file-backed LUKS2 and LUKS1 volumes (ticket 33).
- `test/shell.d/drive-password-test.sh` checks that an Apple password change records the owner's new slot through `luks-slots`, including after an interruption, and that x86 never calls it.
