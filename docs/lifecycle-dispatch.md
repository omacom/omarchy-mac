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
| A required operation has no entrypoint | exit 1: `Error: <operation> on <platform> needs <package>, which provides <path>; it is not installed` | same error |
| An optional operation has no entrypoint | no-op, exit 0 | prints nothing, exit 0 |
| The entrypoint fails the trust rules | exit 1: `Error: refusing <path>: ...` (optional operations too) | same error |
| `omarchy-hw-platform` can't settle the platform | exit 1 | exit 1 |
| No operation, or one outside the fixed set | exit 2 with usage | exit 2 |

## Operations

The set is fixed in the dispatcher; adding one is an upstream change. The operations provisioning calls take no arguments and work on fixed paths: `/var/lib/omarchy/provisioning` holds the staged install key (`luks-key`) and the re-key journal (`luks-rekey.state`). The other operations define their arguments when their caller is wired.

| Operation | Called | Contract | Apple | Caller |
| --- | --- | --- | --- | --- |
| `provision-prepare` | Owner provisioning, at the start of every setup attempt, before the owner is asked anything | Succeeds when the platform can finish setup on this machine. On failure its stderr is shown on tty1 and logged, and the attempt fails into the usual retry screen. It must leave nothing a retry can't repeat. | required | `omarchy-provision-owner` |
| `provision-commit` | Owner provisioning, during the LUKS re-key: after the owner's key is added, before any other slot is retired | Removes every boot-time copy of the staged key and its unlock configuration from the platform's boot chain, and rebuilds the boot files so the next boot asks for the password. Idempotent. If it fails, it leaves or restores a boot chain that still unlocks unattended with the staged key, so the retry boots. | required | `omarchy-provision-owner` |
| `provision-verify` | Owner provisioning, whenever it asks whether the staged unlock remains: before the re-key, during it, and before setup drops `pending` | Read-only. Exits 0 only when the boot chain holds no staged key or unlock configuration. Any other status counts as "remains", so setup never finishes. | required | `omarchy-provision-owner` |
| `reset-prepare` | Factory reset, before switching to the factory root | Stages the platform's boot state (unlock, command line, rebuilt boot files) for the factory root | required | ticket 34 |
| `reset-verify` | Factory reset, before committing the switch | Proves the factory root boots on this boot chain (kernel, firmware and DTB coherence, loader hashes) | required | ticket 34 |
| `reset-rollback` | Factory reset, when anything fails after `reset-prepare` | Restores the previous boot state | required | ticket 34 |
| `update-preflight` | Update, before the keyring and package transaction | Refuses an update the platform can't boot afterwards. A failure stops the update. | optional | `omarchy-update-boot preflight` (`omarchy update`) |
| `update-verify` | Update, after the last package step: the transaction, migrations, the post-update hook, AUR, mise and orphans | Read-only. Verifies the boot chain boots the updated system, whose new kernel may still wait for its reboot. A failure leaves the update unfinished: it exits non-zero and offers no reboot. | required | `omarchy-update-boot verify` (`omarchy update`) |
| `boot-rebuild` | Whenever upstream rebuilds boot files: owner provisioning after a factory reset left entries for another machine identity, later kernel and initramfs hooks, snapshots and command-line changes | Rebuilds the platform's boot files, after upstream has started the Limine menu over where there is one | required | `omarchy-provision-owner`; ticket 36 |

## Platform registration

Registration is code in `bin/omarchy-lifecycle-dispatch`, not configuration. No file, environment variable or `PATH` entry decides what runs as root.

| Platform | Implementation directory | Package | Required operations |
| --- | --- | --- | --- |
| `apple-silicon` | `/usr/lib/omarchy/mac-boot` | `omarchy-mac-boot` | all except `update-preflight` |
| `generic`, `generic-aarch64`, `qualcomm` | none | none | none: every operation is a no-op, and callers keep their generic path |

The entrypoint for an operation is `<implementation directory>/<operation>`. A registered platform's required operations must be shipped. Its optional operations may be left out, and then they are no-ops.

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

- `platform_ready` runs `provision-prepare` at the start of each setup attempt, before the keyboard and account forms. Without `omarchy-mac-boot` on a Mac, the owner sees the dispatcher's error naming the package, the log records it, and the attempt ends in the retry or root-shell screen.
- The shared re-key (`install/provisioning/luks-rekey.sh`) asks the caller for two callbacks: `luks_auto_unlock_present` and `luks_auto_unlock_drop`. `unlock_owner` resolves `provision-commit` and `provision-verify` once per process. If both resolve, the platform owns the unlock: drop is `provision-commit`, and present is `provision-verify` failing. If neither resolves, the Limine UKI callbacks run unchanged (x86, Snapdragon, generic aarch64). If only one resolves, or resolution fails, the unlock counts as present and can't be dropped, so setup never finishes.
- After a factory reset left Limine entries for another machine identity, `refresh_boot_entries` starts the menu over from the template (core), then runs `boot-rebuild` if the platform implements it, and `limine-update` otherwise.
- Everything else stays upstream: the wizard, account and login, the journal, slot retirement, the proof that the staged key opens nothing, and cleanup.

### Update (`bin/omarchy-update`)

- `omarchy-update-boot preflight` runs after the dev checkout update and before the keyring and system packages change. A refusal stops the update like any failed step.
- `omarchy-update-boot verify` runs after the last package step. When it fails, the update still checks its log, refreshes the update indicator and releases Stay Awake, then says the update is not finished and exits 1 without `omarchy-update-restart`, so no reboot is offered.
- `omarchy-update-boot` resolves the operation as the user first and runs it with `sudo` only when it resolves to an entrypoint, so an update with nothing to run never asks for root. A failed resolution, such as a Mac without `omarchy-mac-boot`, fails the step with the dispatcher's message.
- The update path rebuilds no boot file itself: package hooks do, and `update-verify` catches what they missed.

## Apple implementation

`omarchy-mac-boot` implements the Apple operations. Draft #503 already moved the Apple boot code into `packages/omarchy-mac/boot/`, with sourced modules in `/usr/lib/omarchy-mac/boot` and commands in `/usr/bin`. Its modules become the implementation with small entrypoints around them:

| #503 today | Operation | Change |
| --- | --- | --- |
| `omarchy-provision-owner` sources `/usr/lib/omarchy-mac/boot/provision.sh` when `omarchy-hw-apple-silicon` succeeds, and refuses with "Required omarchy-mac-boot provision support is unavailable" | `provision-prepare` | The refusal becomes the dispatcher's required-operation error. The entrypoint keeps the checks from #503's Apple block in `run_setup`: the LUKS device is found, and a `finished` `encrypt.state` has no leftover unlock. |
| `apple_rekey_boot` in `lib/provision.sh` (drop `rd.luks.key=` from `/etc/default/grub`, `mkinitcpio -P`, `omarchy-mac-boot-update`), the `/boot/omarchy/luks-key` half of `shred_luks_keyfiles`, then `mark_encrypt_finished` | `provision-commit` | The entrypoint sets the globals the module expects (`GRUB_DEFAULT`, `LOG_FILE`, `log_step`, `say`) to fixed values, sources the module and calls it. On failure it restores the boot key and `rd.luks.key=`. |
| The Apple half of `require_finished_luks`, and `run_provisioning`'s refusal before `encrypt.state` reaches `finished` | `provision-verify` | New read-only entrypoint: no `/boot/omarchy/luks-key`, no `rd.luks.key=` in the GRUB defaults or in the Limine command line `omarchy-mac-limine-cmdline` derives from them, `encrypt.state` absent or `finished` |
| `stage_luks_rekey_apple` in `lib/factory-reset.sh` | `reset-prepare` | Ticket 34 |
| `rebuild_next_boot_apple` (factory-kernel coherence refusal, rebuild in the factory root, `verify_limine_hashes`) | `reset-prepare`, `reset-verify` | Ticket 34 |
| mx-mac's reset rollback, not yet in #503 | `reset-rollback` | Ticket 34 |
| `omarchy-mac-boot-update` | `boot-rebuild` | Thin entrypoint around the existing command. Provisioning uses it now. |
| `omarchy-apple-silicon-boot-check` | `update-verify` | `entrypoints/update-verify` runs the check with the new kernel's reboot allowed to be pending: the kernel and initramfs in `/boot`, the device-tree set, m1n1 stage 2 and U-Boot on the system ESP, and Limine's loader, menu and UKI on that same ESP. On failure it says not to reboot and how to rebuild the boot files. |

- **Packaging:** `packages/omarchy-mac/boot/install` gains one loop that installs `entrypoints/*` as `/usr/lib/omarchy/mac-boot/<operation>`, mode 755. The modules stay where #503 put them and are sourced by absolute path.
- **Owner and recovery slots:** #503's `rekey_luks_apple` sequence folds into the shared journal. Its owner and recovery slot steps are core (`luks-rekey.sh`, `luks-recovery.sh`). Only its boot step is `provision-commit`.
- **Recovery passphrase:** #503 prepares it (`prepare_luks_recovery`) only on Apple. Whether every encrypted install gets one is a core decision for ticket 33, not a dispatch operation.

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
  - setup stopping before the owner form when the boot package is missing or not ready
  - the stale-entry refresh rebuilding through `limine-update` on x86 and the boot package on Apple
  - the worker failing closed without it
