# Btrfs on Omarchy Mac

The x86 Omarchy Quattro ISO installs onto btrfs and gets snapshots, snapper
retention, and `omarchy-system-factory-reset` for free.
`omarchy-system-btrfs-migrate` gives an Asahi Alarm install the same root
layout. What it has to do depends on which Asahi Alarm image you installed:

- **an ext4 image** — the partition is rebuilt as btrfs with `@`, `@home` and
  `@log`, optionally inside a LUKS2 container.
- **a btrfs image** — Asahi Alarm's btrfs variants already create `@` and
  `@home`, so the filesystem is left alone and only the missing pieces are
  added. With `--encrypt` the partition is encrypted in place; without it,
  there is nothing left to do and the tool says so.

Neither path is available from the installer itself: Asahi Alarm has no
encryption option, so a LUKS root on Apple Silicon has to be arranged
afterwards, and this is that step.

## What the machine has to look like first

**`/boot` must be a separately mounted EFI partition.** GRUB is installed with
its prefix under `/boot` — its modules, `grub.cfg`, the kernel and the
initramfs all live there, and it reads them before anything can be unlocked.
Some Asahi Alarm images instead keep `/boot` as a directory on the root
filesystem and mount the ESP at `/boot/efi`, leaving only the EFI stub outside
the root. On that layout, encrypting the root hides GRUB's own prefix from it
and the machine boots to `grub rescue>`:

```
error: no such device: <btrfs uuid>
error: file '/@/boot/grub/arm64-efi/normal.mod' not found.
Entering rescue mode...
```

Converting an ext4 root breaks it the same way, for a different reason: the
reformat changes the filesystem UUID that GRUB's embedded `search` looks for.

The tool checks `/boot` and refuses on that layout rather than producing an
unbootable machine. `omarchy-system-boot-to-esp` converts it: it copies `/boot`
onto the EFI partition, mounts the partition there instead of at `/boot/efi`,
reinstalls GRUB with its prefix on that partition, and rebuilds the initramfs.

```bash
curl -LO https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/bin/omarchy-system-boot-to-esp
sudo bash omarchy-system-boot-to-esp
# reboot, confirm the machine still comes up, then encrypt
```

That is the layout encrypted Arch installs normally use, and the Asahi docs
list it as supported — the OS ESP is "mounted at `/boot/efi` or `/boot`".
Firmware updates keep working: `update-m1n1` locates the system ESP itself
rather than reading `/boot/efi`. The originals stay in `/boot.old` until you
delete them, and because GRUB's prefix now sits on unencrypted vfat, a bad
boot is recoverable from the rescue prompt:

```
set prefix=(hd0,gptN)/grub
insmod normal
normal
```

**Reboot and confirm the machine boots before encrypting.** That separates a
layout problem from an encryption problem, while the layout problem is still
cheap to fix.

## When to run it

Immediately after the Asahi Alarm installer, on the first boot into Arch,
**before** `bootstrap.sh`.

The ext4 conversion stages the whole system through RAM, which is only safe
while the install is small and disposable; it refuses to run when the used
space does not comfortably fit in memory. The in-place encryption has no such
limit — it copies nothing and resumes if interrupted — but the layout it
produces (`@fresh` in particular) is only meaningful on a fresh install.

## Usage

As root on the fresh install:

```bash
curl -LO https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/bin/omarchy-system-btrfs-migrate
bash omarchy-system-btrfs-migrate --encrypt   # omit --encrypt to stay unencrypted
```

Confirm at the prompt (`convert` on ext4, `encrypt` on btrfs), reboot, and the
work runs early in boot, before the root is mounted.

On an **ext4** root:

1. The system is copied into RAM (a fresh install is a few GB).
2. With `--encrypt`, a LUKS2 container is created — you choose the disk
   passphrase on the console at this point. Every later boot asks for it.
3. The partition is reformatted as btrfs with subvolumes `@` (root), `@home`,
   and `@log`, and the system is restored into `@`.
4. A read-only snapshot `@fresh` of the just-converted system is taken.
5. Boot continues straight into the converted root; a one-shot service on
   that boot regenerates the GRUB config and initramfs, then removes itself.

On a **btrfs** root with `--encrypt`:

1. The filesystem is shrunk by 64 MiB to free the space cryptsetup needs for a
   LUKS2 header.
2. You choose the disk passphrase on the console, and `cryptsetup reencrypt`
   encrypts the partition in place. Every block is rewritten, so this is the
   slow part — minutes, scaling with partition size rather than with how much
   is stored on it. Nothing is copied anywhere and the filesystem UUID does
   not change, so `fstab` and `grub.cfg` keep working as written.
3. `@log` is created (Asahi Alarm's images stop at `@` and `@home`) and
   `/var/log` is moved into it; the read-only `@fresh` snapshot is taken.
4. Boot continues into the now-encrypted root, and the same one-shot finish
   service regenerates the GRUB config and initramfs.

Interrupting step 2 — a power cut, a hard reset — costs only the time spent so
far. The half-encrypted state is recorded in the LUKS2 header, the hook finds
the partition again by PARTUUID on the next boot, and the pass resumes after
you enter the passphrase.

Then proceed with the normal Omarchy install (`bootstrap.sh`). When
`install.sh` finishes on a btrfs root it snapshots the installed system as
`@factory`, and the snapper config that upstream ships activates instead of
being skipped.

## What you get

- **snapper** — pacman transactions get pre/post snapshots with Omarchy's
  retention config; `sudo snapper -c root list` to see them.
- **`sudo omarchy-system-factory-reset`** — returns the machine to the
  fully-installed, no-user state captured in `@factory`.
- **`@fresh`** — the pre-Omarchy baseline. Rolling back to it and re-running
  the installer is the fast way to test install changes end to end (below).

## The unlock prompt

The conversion boot prompts on the bare console: Plymouth is not installed
yet, and neither is a theme for it. Once Omarchy is installed the prompt is
the branded one — `omarchy_hooks.conf` orders the `plymouth` hook ahead of
`encrypt`, the stock `encrypt` hook hands the prompt to
`plymouth ask-for-password`, and `install/login/alt-bootloaders.sh` puts
`splash` on the GRUB command line for the machines that boot without limine,
which every Mac does.

## Rolling back to the pre-Omarchy state

`@fresh` is the fresh Asahi Alarm system from just after the migration. Run `omarchy-snapshot restore` and select `@fresh` to restore that root while retaining `@home` and `@log`. The Mac recovery helper transfers the existing nested Snapper backend into the restored root, preserving its history and subvolume identity. Raw snapshot-and-rename commands omit nested subvolumes and leave future snapshots broken.

Finish other snapshot, backup and Btrfs maintenance first, and do not start concurrent direct Snapper writers during recovery. Reboot before another restore. The command prints the exact undo route through the recovery helper retained under `@old-<timestamp>`; keep that root until recovery and undo are verified. Undo does not require the restored baseline to contain Omarchy or Python, but does require the existing Bash, Btrfs, mount and systemd tools. A baseline without a Snapper configuration stays unconfigured, with the history retained. Update older Omarchy software before using its own recovery commands again.

The root exchange uses two renames. A power loss between them can leave `@` absent and require a rescue boot of the retained root before running the retained helper with `repair`. The UUID-bound transaction receipt permits verified rollback; it is not a bootloader recovery mechanism. Do not interrupt recovery or assume the ESP is covered.

Recovery can automatically reattach history lost by an earlier restore only when the current root's Btrfs parent UUID identifies a snapshot inside exactly one retained backend. Ambiguous state, custom snapshot mounts and conflicting paths are preserved for manual inspection.

## Limitations

- `/boot` is the (vfat, unencrypted) ESP — required, see above. Snapshots and
  rollbacks never cover the kernel, initramfs, or GRUB config. After rolling
  `@` back across a kernel update, run `mkinitcpio -P` if modules and kernel
  disagree.
- The RAM staging makes the ext4 path a fresh-install tool, not a general
  ext4→btrfs migrator for a system with data on it. The encryption path has no
  such constraint, but it has never been asked to encrypt a machine anyone
  cared about, so treat a backup as mandatory.
- Only the busybox `encrypt` hook is wired up. An initramfs built around the
  systemd hooks (`sd-encrypt`) is rejected rather than half-configured.
- Factory reset supports the existing Asahi GRUB layout with the ESP mounted at `/boot`, the selected factory root's packaged kernel image/modules and its standard default-image preset. It stages and verifies matching kernel, initramfs, GRUB configuration and Asahi boot bundle before selecting the new root. Other boot topologies, ambiguous kernels and custom active preset options need explicit support and are refused before reset preparation.

## Factory reset and retained history

`sudo omarchy-system-factory-reset` displays every subvolume path and UUID it intends to erase before the existing `reset` confirmation. This includes the displaced root, previous `@old-*`/`@omarchy-old-*` roots, `@fresh`, home/log, and every nested snapshot. Legacy names alone do not establish ownership: confirm only if every displayed identity belongs to the reset. Unlisted administrator subvolumes remain outside the reset. Mounted descendants, new nested subvolumes or changed UUIDs stop cleanup and keep provisioning blocked.

The command delivers the current reset worker, owner setup and required helpers into the selected historical factory root. It removes old account credentials, account database backups and previous provisioning state before capturing a sanitized replacement `@factory`. The first boot erases only the confirmed inventory and recreates home/log with recorded identities; a partial failure retains its receipt for retry. This is deletion, not forensic secure erase.

On encrypted GRUB installations the verified provisioning initramfs includes a temporary auto-unlock key. Owner setup rebuilds the boot files without that key, verifies the owner's LUKS slot, then retires the previous slots. An interrupted retirement is retried with the same confirmed owner disk password, even if the temporary key's slot has already been removed. Do not discard a pending re-key receipt or substitute a different owner password during that retry.

Finish package updates, snapshots and other disk maintenance before reset. Current Omarchy updates share the reset exclusion lock; direct administrator boot/key/subvolume writes must remain stopped. A staged reset blocks further updates until its reboot and first-boot wipe complete. Ordinary GRUB publication/root exchange failures reconcile the exact original boot bytes, root and factory identities; failed staging remains available for inspection. Do not manually delete an interrupted journal or rename unfamiliar roots. A power loss across the separate boot-file/root renames can still require a rescue boot and receipt-based manual reconciliation; the journal is not a firmware rollback mechanism.

The existing Limine generator remains the x86 route. Its generator/UKI behavior is separate from the Asahi GRUB qualification. A generic ARM GRUB layout can use an already maintained `vmlinuz-linux` alias of the matching packaged `Image` for component testing; that alias is not created by reset and does not establish support for stock `linux-aarch64` package-update synchronization. A stale active alias is refused.

## Testing changes to the migration

`tests/test-btrfs-migrate-rehearsal.sh` (as root) exercises the conversion
core — staging, LUKS, subvolume layout, restore fidelity, fstab generation,
and the in-place encryption of an existing btrfs root — against a loop device
without touching the machine's disks.
