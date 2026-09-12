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

`@fresh` is the fresh Asahi Alarm system from just after the migration. To
rewind the whole install (this discards `/`, keeps `@home` and `@log`):

```bash
sudo mkdir -p /mnt/top
sudo mount -o subvolid=5 "$(findmnt -no SOURCE / | sed 's/\[.*\]//')" /mnt/top
sudo btrfs subvolume snapshot /mnt/top/@fresh /mnt/top/@new   # writable clone
sudo mv /mnt/top/@ /mnt/top/@old-$(date +%s)
sudo mv /mnt/top/@new /mnt/top/@
sudo reboot
```

After verifying the reboot, delete the parked `@old-*` subvolume from
`/mnt/top`. Note `@home` survives the rollback — delete and recreate it too if
you want the full fresh state.

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
- On encrypted installs, `omarchy-system-factory-reset`'s provisioning-window
  auto-unlock embeds a throwaway keyfile in the initramfs and puts
  `cryptkey=rootfs:/etc/omarchy/provisioning.key` on the GRUB command line.
  First-boot setup re-keys LUKS to the new owner's password and rebuilds GRUB
  without that key. Machines that boot Limine still go through `limine-update`
  and the Limine entry-tool drop-in.

## Testing changes to the migration

`tests/test-btrfs-migrate-rehearsal.sh` (as root) exercises the conversion
core — staging, LUKS, subvolume layout, restore fidelity, fstab generation,
and the in-place encryption of an existing btrfs root — against a loop device
without touching the machine's disks.
