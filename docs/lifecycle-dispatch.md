# Lifecycle dispatch

Omarchy owns the boot lifecycle flows: the owner wizard, account creation, LUKS discovery, retry journals, snapshots, the migration runner and the update flow. Some platforms boot through a chain those flows can't drive generically. Apple Silicon Macs boot m1n1 → U-Boot → Limine, keep the install key on an ext4 boot partition and name it on the kernel command line. For those platforms, the flows call a small fixed set of operations through `bin/omarchy-lifecycle-dispatch`, and a platform boot package implements them as root-owned entrypoints. System and user setup, and the installers of apps a platform needs to adjust, call a few more, which a platform's runtime package implements, so its own setup runs from Omarchy's without an inline platform branch. Every other platform keeps the generic path, and each dispatch call is a no-op there.

## The command

```
omarchy-lifecycle-dispatch <operation> [arguments...]
omarchy-lifecycle-dispatch --resolve <operation>
```

The first form runs the operation. `--resolve` prints the entrypoint the operation would run, or nothing when the operation is a no-op on this machine. A caller uses it when a platform implementation replaces a generic step (see [Callers](#callers)).

| Situation | Run | `--resolve` |
| --- | --- | --- |
| The platform registers no package (`generic`, `generic-aarch64`, and `qualcomm` today) | no-op, exit 0 | prints nothing, exit 0 |
| The entrypoint exists and passes the trust rules | execs it; its exit status is the result | prints its path |
| A required operation has no entrypoint, and the package is not installed | exit 3 (an entrypoint's own status could also be 3; with `--resolve` it is only this): `Error: <operation> on <platform> needs <package>, which provides <path>; it is not installed` | same error |
| A required operation has no entrypoint, but the package is installed (its pacman record says so) | exit 1: `Error: <operation> on <platform> needs <path>, which <package> <version> does not provide; update <package>` | same error |
| An optional operation has no entrypoint (every setup and app-install operation is optional, so none of them ever fails for a missing package) | no-op, exit 0 | prints nothing, exit 0 |
| A user operation (`setup-user`, `post-install`, `pre-remove`) is run as root | exit 1: `Error: <operation> runs as the user, never as root` | same error |
| The entrypoint fails the trust rules | exit 1: `Error: refusing <path>: ...` (optional operations too) | same error |
| `omarchy-hw-platform` can't settle the platform | exit 1 | exit 1 |
| No operation, or one outside the fixed set | exit 2 with usage | exit 2 |

## Operations

The set is fixed in the dispatcher; adding one is a change to Omarchy. Every operation runs as root except `setup-user`, `post-install` and `pre-remove`, which run as the user. The `provision-*` operations take no arguments and work on fixed paths: `/var/lib/omarchy/provisioning` holds the staged install key (`luks-key`) and the re-key journal (`luks-rekey.state`). `luks-slots` takes the slot numbers it records. Factory reset names the factory root it is about to activate, since that is not `/` yet, and hands `reset-commit` the throwaway key on standard input, never in arguments.

| Operation | Called | Contract | Apple | Caller |
| --- | --- | --- | --- | --- |
| `provision-prepare` | Owner provisioning, at the start of every setup attempt, before the owner is asked anything | Succeeds when the platform can finish setup on this machine. On failure its stderr is shown on tty1 and logged, and the attempt fails into the usual retry screen. It must leave nothing a retry can't repeat. | required | `omarchy-provision-owner` |
| `provision-commit` | Owner provisioning, during the LUKS re-key: after the owner's key is added, before any other slot is retired | Removes every boot-time copy of the staged key and its unlock configuration from the platform's boot chain, and rebuilds the boot files so the next boot asks for the password. Idempotent. If it fails, it leaves or restores a boot chain that still unlocks unattended with the staged key, so the retry boots. | required | `omarchy-provision-owner` |
| `provision-verify` | Owner provisioning, whenever it asks whether the staged unlock remains: before the re-key, during it, and before setup drops `pending` | Read-only. Exits 0 only when the boot chain holds no staged key or unlock configuration. Any other status counts as "remains", so setup never finishes. | required | `omarchy-provision-owner` |
| `reset-prepare <factory-root> [<luks-device>]` | Factory reset, once the factory root is cloned and scrubbed, before switching to it. The device is there only when the root is encrypted. | Stages the platform's boot state for the factory root: the unlock's command line, the rebuilt boot files, and encryption state reopened for the next owner. It keeps what `reset-rollback` restores, and writes no key. | required | `omarchy-system-factory-reset` |
| `reset-verify <factory-root>` | Factory reset, right after `reset-prepare` and before the throwaway slot is added and the switch committed | Read-only. Proves the rebuilt boot files boot the factory root on this boot chain. A failure rolls the reset back. | required | `omarchy-system-factory-reset` |
| `reset-commit` (key on standard input) | Factory reset, once the factory root is the active root | Puts the throwaway key where the staged unlock reads it, so the first boot unlocks unattended until owner setup re-keys, and drops what `reset-rollback` would restore. A failure is logged, not fatal: that boot asks for the current disk password once. | required | `omarchy-system-factory-reset` |
| `reset-rollback` | Factory reset, when anything fails after `reset-prepare` started and before the factory root is active, `reset-prepare`'s own failure included | Restores the previous boot state. Nothing to restore is a success. | required | `omarchy-system-factory-reset` |
| `update-verify` | Update, after the last package step: the transaction, migrations, orphan removal and AUR packages | Read-only. Verifies the boot chain boots the updated system, whose new kernel may still wait for its reboot. A failure leaves the update unfinished: it exits non-zero and offers no reboot. | required | `omarchy-update-boot` (`omarchy update`) |
| `update-takeover <path>...` | Update, when an Omarchy package's upgrade stopped only on files no package owns, before they are moved aside for the retry | Read-only. Gets those paths. Exit 0 lets the takeover go ahead; any other status keeps every file where it is, and the update fails as it would have without the retry. A platform whose boot chain or image writes files it can't do without refuses those. | required | `omarchy-update-system-pkgs-when-conflicted` (`omarchy update`) |
| `luks-slots` | Owner provisioning, once the re-key keeps only the owner's slot and the acknowledged recovery slot, before it destroys the staged key; the disk password change, once the owner's new key is confirmed; the password reset with the recovery key, once the owner's new password and the recovery key are the disk's only keys and the accounts follow | `luks-slots owner=<slot> [recovery=<slot>]` records the root volume's kept slots wherever the platform's boot checks look for them. Without `recovery=` the recorded recovery slot stays; an empty one records none. Idempotent. It fails when a slot is not in the LUKS header, and the caller then retries. A platform that implements it also has owner provisioning create a recovery passphrase (see [Recovery passphrase](#recovery-passphrase)). | required | `omarchy-provision-owner`, `omarchy-drive-password`, `omarchy-drive-recover` |
| `setup-boot [image-first-boot]` | Hardware setup's last leaf (`install/hardware/platform-setup.sh`), before `setup-system`, on every install and rerun of `omarchy-apply-hardware`, and on an image's first boot with `image-first-boot` | The platform boot package's own boot setup (on a Mac, the GRUB console settings and the Limine activation). Idempotent. With `image-first-boot` it asks for the boot-file rebuild by creating `/var/lib/omarchy/image/boot-rebuild` where it would build one. A failure fails the leaf, and `setup-system` does not run. | required | `install/hardware/platform-setup.sh` |
| `setup-system [image-first-boot]` | Hardware setup, as its last leaf (`install/hardware/platform-setup.sh`), after `setup-boot`, on every install and every rerun of `omarchy-apply-hardware`. In an image build it is queued with the other leaves and runs on the machine's first boot, with `image-first-boot`. | The platform's machine-wide setup: services, configuration and drivers its runtime package owns. Idempotent. Needs no network with `image-first-boot` (that boot may be offline), and there it asks for a boot-file rebuild by creating `/var/lib/omarchy/image/boot-rebuild` rather than building one, since the deferred setup rebuilds once after its last step. A failure fails the leaf, and on an image's first boot the step stays queued for the next boot. | optional | `install/hardware/platform-setup.sh` |
| `setup-user` | Runs as the user being set up: at the end of user finalization (`install/user/platform-setup.sh`, from `install/user/all.sh`), and in first run once the session is up. Finalization inside an image build skips it; first run on the machine runs it. | The platform's per-user setup. Idempotent. Finalization may have no session (the ISO chroot, owner setup), so work that needs one (a user unit started now, a D-Bus call) is left for the first-run call, and its absence is not a failure. A failure fails finalization or the first-run step, so first run stays pending and runs it again at the next login. | optional | `install/user/platform-setup.sh`, `omarchy-provision-first-run` |
| `post-install <app>` | Runs as the user, from an installer once `<app>` is installed and Omarchy's own setup of it is done: `chromium`, `chrome`, `edge`, `brave`, `brave-origin`, `firefox`, `zen` (`omarchy-install-browser`) and `steam` (`omarchy-install-gaming-steam`) | The platform's adjustments for that app, such as its browser flags or a launcher the app needs on this hardware (which may install a package through `sudo`). Idempotent. A failure fails the install. | optional | `omarchy-install-browser`, `omarchy-install-gaming-steam` |
| `pre-remove <app>` | Runs as the user, from a remover before `<app>`'s packages go: `steam` (`omarchy-remove-gaming-steam`) | Undoes what `post-install <app>` added, packages that depend on the app first. Idempotent; nothing to undo is a success. A failure stops the removal before anything is removed. | optional | `omarchy-remove-gaming-steam` |
| `migrate` | The platform migration (`migrations/1790347292.sh`), when `omarchy-migrate` runs it | Moves the machine onto the platform's official package set in place, or does nothing when the platform has no target set yet. Idempotent and resumable: a machine already on the target, or one whose migration waits for a reboot, exits 0. A refusal that changed nothing exits 75, which leaves the migration pending without stopping later migrations or the update; a failure exits with any other non-zero status and stops them. | optional | `migrations/1790347292.sh` |

Snapshot restore is not an operation: a Limine machine restores through `limine-snapper-restore`, and a platform boot package that checks a restore does so through limine-snapper-sync's own hooks.

## Platform registration

Registration is code in `bin/omarchy-lifecycle-dispatch`, not configuration. No file, environment variable or `PATH` entry decides what runs as root.

| Platform | Implementation directory | Package | Required operations |
| --- | --- | --- | --- |
| `apple-silicon` | `/usr/lib/omarchy/mac-boot` | `omarchy-mac-boot` | all its operations except `migrate` |
| `apple-silicon`: `setup-system`, `setup-user`, `post-install`, `pre-remove` | `/usr/lib/omarchy/mac` | `omarchy-mac` | none |
| `generic`, `generic-aarch64`, `qualcomm` | none | none | none: every operation is a no-op, and callers keep their generic path |

The entrypoint for an operation is `<implementation directory>/<operation>`. A registered platform's required operations must be shipped. Its optional operations may be left out, and then they are no-ops.

On a Mac, owner provisioning and factory reset have no other path, so their operations are required: a Mac without `omarchy-mac-boot`'s entrypoints stops before the owner form or before the reset is confirmed, with the dispatcher's error naming the package, where the generic Limine path would leave the boot-partition key behind or rebuild a UKI the Mac does not boot. `luks-slots` is required because the Mac's boot checks prove the owner's and the recovery slot. `update-verify` is required because nothing else checks what an update left in a Mac's boot chain. `update-takeover` is required because a Mac's boot chain and image write files no package owns, so a Mac whose boot package can't vouch for a takeover keeps its files and the update stops at the conflict. `setup-boot` is required because the Mac's boot setup has no other path in hardware setup: a Mac whose `omarchy-mac-boot` lacks it stops the hardware leaf, asking for the update, where an optional operation would skip the Limine activation. `migrate` is optional: a Mac without it has nothing to move to yet. System and user setup and the app-install hooks belong to the Mac's runtime package, `omarchy-mac`, not its boot package, and are optional: a Mac without `omarchy-mac` gets Omarchy's generic setup and installs.

## Trust rules

- The dispatcher runs as `bash -p`, so a root caller's `BASH_ENV` and exported functions run nothing in it, and it refuses an ordinary Bash launch. As root it uses a fixed `PATH`, runs the detector installed beside it with nothing in its environment but that `PATH` (the detector reads only the live device tree as root), and resolves only the fixed implementation directory.
- An entrypoint runs only if it is a regular executable file. Neither the file nor any directory up to `/` may be a symlink, and all of them must be owned by root and not writable by group or others. An entrypoint that fails these rules is refused, even for an optional operation.
- The entrypoint runs with an empty environment apart from `PATH=/usr/local/sbin:/usr/local/bin:/usr/bin`. It gets the caller's arguments, standard streams and working directory. Entrypoints use fixed paths, never environment variables. Anything that can also run them directly re-checks the platform itself.
- `setup-user`, `post-install` and `pre-remove` refuse root, so they never run as anyone but their caller. Their entrypoints follow the same trust rules, and besides `PATH` they get only these, when the caller has them set: `HOME`, `USER`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME` (where the user's configuration and setup markers live), `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, `WAYLAND_DISPLAY` and `OMARCHY_PATH`.
- For unprivileged tests, `OMARCHY_LIFECYCLE_ROOT` (absolute) prefixes the implementation directory, and the detector's fixture roots apply. Inside that root, files the caller owns count as root's. Root ignores both.

## Callers

A dispatch point takes one of two shapes:

- **A platform step with no generic counterpart:** `omarchy-lifecycle-dispatch <operation> || fail`. It is a no-op on platforms without a boot package.
- **A platform implementation that replaces a generic step:** `--resolve <operation>`. A path means dispatch the operation, an empty result means run the generic step, and a failure fails closed.

Failing closed holds on every platform: where `omarchy-hw-platform` can't settle the platform (contradicting device-tree evidence, for one), first-boot setup and factory reset stop instead of guessing a boot path, and an update ends unverified, without the reboot prompt. An update has no check before its packages change; a platform that needs one adds the operation with its first entrypoint.

### Owner provisioning (`bin/omarchy-provision-owner`)

- `platform_ready` runs `provision-prepare` and resolves `luks-slots` at the start of each setup attempt, before the keyboard and account forms. If either fails, the owner sees its error, the log records it, and the attempt ends in the retry or root-shell screen.
- The shared re-key (`install/provisioning/luks-rekey.sh`) asks the caller for two callbacks: `luks_auto_unlock_present` and `luks_auto_unlock_drop`. `unlock_owner` resolves `provision-commit` and `provision-verify` once per process. If both resolve, the platform owns the unlock: drop is `provision-commit`, and present is `provision-verify` failing. If neither resolves, the Limine UKI callbacks run unchanged (x86, Snapdragon, generic aarch64). If only one resolves, or resolution fails, the unlock counts as present and can't be dropped, so setup never finishes.
- After a factory reset left Limine entries for another machine identity, `run_provisioning` starts the menu over from the template and runs `limine-update`, on every platform.
- Where `luks-slots` resolves, `run_setup` creates the recovery passphrase before the worker starts (see [Recovery passphrase](#recovery-passphrase)). The shared re-key calls the caller's `luks_record_slots` once it has verified the kept slots and before it destroys the staged key; `omarchy-provision-owner` runs `luks-slots owner=<slot> recovery=<slot or empty>` there, a no-op where nothing records them.
- Everything else stays as it is: the wizard, account and login, the journal, slot retirement, the proof that the staged key opens nothing, and cleanup.

### Factory reset (`bin/omarchy-system-factory-reset`)

- `reset_boot_owner` resolves the four reset operations before the reset is confirmed. If all resolve, the platform owns the factory root's boot chain; if none do, the generic path runs unchanged (x86, Snapdragon, generic aarch64: throwaway slot, keyfile in the Limine UKI, `limine-update`, `verify_limine_hashes`). If only some resolve, or resolution fails (a Mac without `omarchy-mac-boot`'s entrypoints), the reset stops before anything changes.
- Where the platform owns it, the order is: authorise with the current passphrase and stage the throwaway in the factory root's `/var/lib/omarchy/provisioning/luks-key`; `reset-prepare`; `reset-verify`; add the throwaway slot; switch the subvolumes; `reset-commit` with the throwaway on standard input. The slot comes after verification, so a failed rebuild adds no credential, and the platform writes its boot-time key only after the switch, so a power loss before it leaves the previous root asking for its password, never unlocked unattended.
- Any failure before the switch runs `reset-rollback` (once `reset-prepare` started), then revokes the slot this attempt added (found by the throwaway key when the add was not confirmed) and deletes the clone: the previous root stays the one that boots, with its boot files and encryption state. Operation output goes to the reset log; a failure shows the operation's last line.
- Everything else stays as it is: the @factory clone, identity and account scrub, provisioning markers and units, LUKS discovery, the passphrase check, the throwaway slot, and the subvolume switch.

### Update (`bin/omarchy-update`)

- `omarchy-update-boot` runs `update-verify` after AUR packages, which the update runs last, so it is the last sudo-capable step; like AUR it follows third-party build code, so it authenticates through the no-update wrapper without a reusable timestamp. When it fails, the update still releases Stay Awake, then says the update is not finished and exits 1 without the reboot prompt.
- It resolves the operation as the user first and runs it with `sudo` only when it resolves to an entrypoint, so an update with nothing to run never asks for root. A failed resolution fails the step with the dispatcher's message, except one: `update-verify` on a machine without its platform's boot package at all (exit 3) warns that the boot files were not verified and lets the update finish. Such a machine predates the package and boots a chain it does not manage; once the package is installed, a failed verification blocks. A package too old to ship `update-verify` blocks, since the fix is one package update away.
- The update path rebuilds no boot file itself: package hooks do, and `update-verify` catches what they missed.
- When an Omarchy package's upgrade stops only on files no package owns, `omarchy-update-system-pkgs-when-conflicted` moves them aside and retries. Before it moves anything it resolves `update-takeover` as the user and, when it resolves, runs `sudo omarchy-lifecycle-dispatch update-takeover <path>...` (inside the update's authorization, which the move needs anyway). A refusal, or a failed resolution (a Mac without its boot package, or with one too old to ship the operation), keeps every file and fails the update as it did before the retry existed. Where nothing resolves, the takeover goes ahead with no extra step.

### Hardware setup (`install/hardware/platform-setup.sh`)

- The last leaf of `install/hardware/all.sh` runs `setup-boot`, then `setup-system`, so both build on every generic leaf. As a `run_logged` leaf it is queued in an image build like any other, and `omarchy-provision-hardware` runs it on the first boot with `OMARCHY_IMAGE_DEFERRED_HARDWARE=1`, which the leaf passes on as `image-first-boot` to both. The environment variable itself never reaches the entrypoints.

### User setup (`install/user/platform-setup.sh`, `bin/omarchy-provision-first-run`)

- The last leaf of `install/user/all.sh` runs `setup-user` at the end of finalization. While `/var/lib/omarchy/image/target` exists the root is still being built, where a normal user's detector would read the build host, so the leaf says so and skips it.
- First run runs `setup-user` again as its own step, after the user units are enabled, now that the session is up. Its failure, like finalization's, leaves first run pending for the next login.

### App installs (`bin/omarchy-install-browser`, `bin/omarchy-install-gaming-steam`, `bin/omarchy-remove-gaming-steam`)

- A browser install runs `post-install <browser>` once the browser's package, policy directory, flags file and theme are in place, and before it says the browser is installed. Steam's install runs `post-install steam` after the package and before the 32-bit drivers and the first launch, and Steam's removal runs `pre-remove steam` before its packages go, so a package the hook added that depends on Steam doesn't stop the removal.
- On a platform that registers none, each call is a no-op and the installer runs as before.

### Disk password change (`bin/omarchy-drive-password`)

- After the system disk's key changed and the login and root passwords follow it, `record_owner_slot` resolves `luks-slots` as the user and, when it resolves, runs `sudo omarchy-lifecycle-dispatch luks-slots owner=<slot>`, so no other platform sees an extra `sudo`. Until that succeeds the journal stays, and the next run finishes the change and records the slot. The new key can land in another slot (cryptsetup 2.8's `luksChangeKey` moves a LUKS1 key to the first free slot, and keeps a LUKS2 one in place), and the boot check would then find a slot the platform did not record.
- The recovery key stays as it is: the system disk refuses it as the current password, and a new password in its form.

### Password reset with the recovery key (`bin/omarchy-drive-recover`)

- An owner who forgot the password unlocks the disk at boot with the recovery key. systemd caches what was typed at the prompt in root's user keyring for 2.5 minutes (crypttab `password-cache=`, on by default). `omarchy-drive-recover-check.service`, before the login screen, arms `omarchy-drive-recover.service` for that boot when a cached key has the recovery key's form, or a reset journal is pending. The reset runs as root on tty1: the recovery key must open a slot, tested with `--token-type passphrase-only` like every key check, and authorizes a new password. It needs no sudo and no password the owner forgot. If the cache expired before the reset started, it asks for the recovery key again.
- Phase `luks` adds the new password with the recovery key and retires every other slot, so the disk ends with the two keys alone. Phase `accounts` sets the login user's and root's passwords, then runs `luks-slots owner=<slot> recovery=<slot>` where it resolves. The journal (`/var/lib/omarchy/drive-recover.state`) holds the disk's UUID, the recovery slot, the login user and the phase, never a key. A boot unlocked with the recovery key can always start phase `luks` again, with a password chosen again; one unlocked with the new password finishes phase `accounts` without asking.
- Owner provisioning arms both units (`omarchy-drive-recover --arm`) once the owner acknowledged a recovery key, so only a platform that records a recovery slot gets them; on x86 today none does. Snapshot boots, read-only roots and a machine still waiting for owner setup never arm the reset, and the reset refuses them when started by hand. As root it takes no path from its environment.

### Platform migration (`migrations/1790347292.sh`)

- One line of dispatch: the migration resolves `migrate` as the user and, when it resolves, runs `sudo omarchy-lifecycle-dispatch migrate`. The entrypoint's status is the migration's: a refusal (75, deferred) or failure leaves it pending, so the next `omarchy-migrate` runs it again and the entrypoint resumes where it stopped.
- The work is machine-wide, but migrations complete per user. Once the entrypoint succeeds, a root-owned marker (`/var/lib/omarchy/migrations/1790347292`) spares every other account the migration and its root prompt.
- Where nothing resolves (every platform but one whose boot package ships `migrate`, including a Mac without its boot package) the migration completes. Like any finished migration it never runs again, and neither does it after an entrypoint exits 0, so a boot package ships `migrate`, and the target it moves machines to, before an Omarchy release carrying this migration reaches them.
- A platform the detector can't settle fails the resolve, so the migration stays pending instead of being skipped.

## Recovery passphrase

The recovery passphrase is core code (`install/provisioning/luks-recovery.sh`); whether setup creates one is the platform boot package's call. A boot package that implements `luks-slots` records a recovery slot for its boot checks, so owner provisioning gives it one to record. Every other platform keeps today's first boot: the owner's password alone, no extra screen. Leaving the decision to the boot package keeps the platform check out of the owner wizard, and turning it on elsewhere is a matter of that platform recording the slots.

- **Order:** `prepare_luks_recovery` runs in the foreground before the worker, on every attempt while the staged key file exists. It reserves a free slot in the journal (`recovery_slot`), adds a new 48-character base32 key there with the staged install key, checks the key opens that slot, records `recovery_shown=0`, shows it, and records `recovery_shown=1` once the owner types the acknowledgement. The key is never written to disk or passed as an argument.
- **Interruption:** an acknowledged key is kept. A key added but not acknowledged is removed and replaced in the same slot, and the owner is told to replace any copy they wrote down when it may have been on screen (`recovery_shown=0`). The worker, which retires every slot but the owner's and the acknowledged recovery slot, starts only after the acknowledgement.
- **The owner's password:** the owner's slot is the re-key's own step, so a retry may still choose a new password while the staged key opens the disk, even after the boot step: the re-key then retires the old password's slot and records the final slots with `luks-slots`. The recovery key is refused as the password.
- **Temporary key:** setup finishes only after the re-key proved the staged key opens nothing, the boot package's `provision-verify` found no boot-time copy, and `luks-slots` recorded the kept slots.

## Platform desktop defaults

A platform's runtime package can also ship Hyprland defaults, without an operation and without a branch in Omarchy's config. Both directories are read from the packaged tree (`/usr/share/omarchy`, which a development checkout in `OMARCHY_PATH` does not replace; `OMARCHY_PACKAGED_PATH` moves it for tests), and Omarchy ships nothing in either.

- **Early: `default/hypr/platform/defaults/*.lua`**, loaded by `default/hypr/omarchy.lua` right after the helpers, before Omarchy's own defaults and the user's files. A chord bound there with `o.bind` replaces Omarchy's default for the same chord (`o.platform_chords`), and a function added to `o.bind_decorators` runs for every later `o.bind`, Omarchy's and the user's, before the bind is made, so it can bind something that has to run first (Hyprland runs a key press's binds in the order they were added). The user's files load after and can unbind or rebind any of it. A file that binds keys honors `omarchy_default_bindings = false`. Settings Omarchy's defaults also set belong in the late directory.
- **Late: `default/hypr/platform/*.lua`**, loaded by `default/hypr/toggles.lua` after the user's files, for defaults that must see the user's: `o.registered_gestures` lists the gestures registered before it, so a default gesture can step aside for the user's own.
- **Key names: `default/omarchy/platform/key-names`**, one `<keysym> <name>` per line, which the keybindings menu shows in place of the keysym (a MacBook's `XF86MonBrightnessUp` is its F2 key).

## Apple Silicon

`omarchy-mac-boot`, from omacom/omarchy-mac, implements the Apple boot operations as small entrypoints around its boot modules and installs them in `/usr/lib/omarchy/mac-boot`. `omarchy-mac`, from the same repository, implements `setup-system`, `setup-user`, `post-install` and `pre-remove` in `/usr/lib/omarchy/mac`. Their documentation describes each one. Nothing Apple-specific lives in Omarchy beyond the registration above.

## Qualcomm

Snapdragon laptops boot Limine with unified kernel images, like x86, and `qualcomm` is unregistered. Every operation is a no-op there, and provisioning uses the Limine UKI callbacks, so Dragon behaves exactly as before. To plug in a Qualcomm implementation:

1. Ship the entrypoints from a Qualcomm boot package as `/usr/lib/omarchy/<name>/<operation>`, root-owned, mode 755. `<name>` is a short directory name, as `mac-boot` is for `omarchy-mac-boot`.
2. Add a `qualcomm)` case to the registration in `bin/omarchy-lifecycle-dispatch` with that directory, the package name, and the operations it requires.
3. Operations it neither requires nor ships stay no-ops. For provisioning, ship `provision-commit` and `provision-verify` together, or neither to keep the Limine UKI path.
4. Move `qualcomm` in `test/shell.d/lifecycle-dispatch-test.sh` from the no-op platforms to its own cases, like Apple's.

## Tests

- `test/shell.d/lifecycle-dispatch-test.sh` covers the dispatcher on every platform fixture:
  - the setup and app-install operations: no-ops off Apple, `omarchy-mac`'s directory on Apple (never `omarchy-mac-boot`'s), no-ops without `omarchy-mac`, the user operations refused as root and given only their allowlisted environment
  - no-ops on x86, generic aarch64 and Qualcomm, even with Mac entrypoints on disk
  - Apple with and without the boot package, and with one too old to ship an operation
  - arguments, exit status and the cleared environment
  - untrusted entrypoints
  - usage errors, and an undetermined platform
  - an ordinary Bash launch, and root ignoring fixture roots, `BASH_ENV` and exported functions
- `test/shell.d/luks-rekey-journal-test.sh` runs owner provisioning through the real dispatcher:
  - the crash-and-resume matrix on x86 (Limine UKI path unchanged, no Mac entrypoint runs, no recovery key) and on Apple with a fake boot package (recovery key, recorded slots), on a slot-table fake and on file-backed LUKS2 and LUKS1 volumes
  - setup stopping before the owner form when the boot package is not ready, missing, or too old to ship the provisioning entrypoints
  - the stale-entry refresh rebuilding through `limine-update`, behind the boot package's `provision-verify` on Apple
  - the worker failing closed without the provisioning entrypoints, or when a boot package implements only one of `provision-commit` and `provision-verify`
- `test/shell.d/luks-recovery-test.sh` covers the recovery passphrase on its own.
- `test/shell.d/drive-recover-test.sh` runs the password reset with the recovery key from a boot's cached unlock, killed after every step and rerun, on the slot-table fake and on file-backed LUKS2 and LUKS1 volumes, on x86 and on Apple (where it records both slots through `luks-slots`), plus an expired cache, a reset started by hand on a snapshot boot, and root ignoring the fixture paths. `test/shell.d/luks-rekey-journal-test.sh` checks that owner setup arms it on Apple and arms nothing on x86.
- `test/shell.d/platform-setup-test.sh` runs the two setup leaves (the system one running `setup-boot`, then `setup-system`, and stopping when either fails or the boot package lacks `setup-boot`) and first run through the real dispatcher: each is the last of its setup, a no-op on x86, `image-first-boot` only on an image's first boot, the user leaf waiting for first run in an image build, and a failing entrypoint failing the leaf and keeping first run pending. `test/shell.d/image-deferred-hardware-test.sh` checks that an image build queues every hardware leaf, the system one included.
- `test/shell.d/first-run-test.sh` checks that a failed finalization keeps first run pending.
- `test/shell.d/platform-app-hooks-test.sh` runs every browser install and Steam's install and removal through the real dispatcher: on Apple each calls its hook once, after the package and flags (before removal for `pre-remove`), and fails with it; on x86 none runs, even with Mac entrypoints on disk.
- `test/shell.d/update-file-conflict-test.sh` checks the takeover: on x86 it goes ahead asking no one; on Apple it goes ahead only when the boot package's `update-takeover` vouches for exactly the files that move, and a refusal, a missing boot package or one too old keep every file.
- `test/shell.d/factory-reset-dispatch-test.sh` runs the reset through the real dispatcher: on x86 with Mac entrypoints on disk that must not run (generic path unchanged), and on Apple into a fake boot package, covering a finished reset, a failed verification and a failed switch that roll back, an unconfirmed throwaway slot found by its key and revoked, a failed commit after the switch, and a missing or partial package.
- `test/shell.d/update-boot-verify-test.sh` runs `omarchy update` through the real `omarchy-update-boot` and dispatcher inside the sudo boundary fixture: no-ops and no root on x86, generic aarch64 and Qualcomm; on Apple, verify after AUR through the no-update wrapper, a failed verification that offers no reboot, and a Mac without the package or with one too old.
- `test/shell.d/drive-password-test.sh` checks that an Apple password change records the owner's new slot through `luks-slots`, including after an interruption, and that x86 never calls it.
- `test/shell.d/migrate-deferred-test.sh` covers the runner: a deferred migration stays pending with its notification while later ones run, is retried on every run, and any other failure still stops the queue.
- `test/shell.d/platform-migration-test.sh` covers the migration: with a stub dispatcher, a refusal, a deferral (passed on as 75) and an undetermined platform leaving it pending and a second account skipping it once it ran; through the real dispatcher, a no-op on x86, generic aarch64, Qualcomm and a Mac without its boot package, and the entrypoint run as root on a Mac with one.
