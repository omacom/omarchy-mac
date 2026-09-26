# Mac image lifecycle VM

This harness runs a built Mac image's lifecycle in disposable aarch64 KVM guests. The image is what the Apple Silicon image producer (`image-builder/` in omacom/omarchy-mac-installer) writes and the installer app puts on a Mac: an ESP tree with m1n1, Limine and the Omarchy UKI, `boot.img` and `root.img`. Each scenario assembles them into one GPT disk and boots it with the command line of the first Limine kernel entry on that disk's ESP, as the Mac would.

## Scenarios

Each scenario is named and runs on its own (`--scenario NAME`, repeatable or comma-separated; `--list` prints them). A scenario that needs a converted, re-keyed disk runs `conversion` first when it was not selected.

| Scenario | What it proves |
| --- | --- |
| `first-boot` | Plain install (`install.conf` with `encrypt=0`): first boot consumes `install.conf`, makes the Mac's pacman keyring and runs the deferred Limine step (the menu is rebuilt for this machine's ID), the owner answers setup, and the console login comes up. The root stays plain (`phase=declined`). Also checks what the first M2 install got wrong: the Plymouth theme is `omarchy` in the configuration and in the UKI's initramfs, and `/.snapshots` is a btrfs subvolume. The wireless regulatory domain is the country of the timezone the owner picked (the image's hardware steps only saw UTC). The default audio sink cannot be checked in a VM (no Apple audio device), so it is recorded as a skip. |
| `conversion` | Encrypted install (no `install.conf`, the app's default): the initrd converts the root to LUKS2 in place, rebuilds the Limine UKI and entries, and continues into `/dev/mapper/root`. Owner setup re-keys the disk: afterwards only the owner's password and the recovery key it showed open it, each in its own slot, so no slot is left for the temporary key. `encrypt.state` is `finished`, both copies of the temporary key are gone, and Limine's command line unlocks the LUKS root with no key file. |
| `second-boot` | The re-keyed disk boots Limine's command line: it asks for the disk password, refuses a wrong one, unlocks with the owner's and reaches the login prompt without emergency mode. |
| `password-change` | The owner runs `omarchy-drive-password` at the console. Afterwards the new password opens the disk and the old one does not, the recovery key still opens it, and the next boot unlocks with the new password, which also logs in the owner and root. |
| `update` | The owner runs `omarchy update -y` at the console of the re-keyed disk, with the guest's network reaching the image's own repositories. The update must exit 0 with its boot files verified (`boot files match` from update-verify) and must not report that it continued without a snapshot; the harness declines the reboot it offers and the removal of orphans. On a test image (`test_image_pin` in `IMAGE`), the pinned runtime packages must still be the set's versions afterwards. The updated disk then boots Limine's command line again, unlocks with the owner's password and reaches the login prompt. `run.txt` records the runtime's versions before and after. Skipped while the image has no `/usr/lib/omarchy/mac-boot/update-verify` (omacom/omarchy-mac#543). |
| `snapshot-restore` | Snapshot boot and restore. Skipped while the image has no `/etc/boot/hooks/pre.d/04-omarchy-mac-snapshot-check` (ticket 36). |
| `factory-reset` | Factory reset through lifecycle dispatch. Skipped while the image has no `/usr/lib/omarchy/mac-boot/reset-prepare` (ticket 34). |

`fresh-install` (the default) is `first-boot`, `conversion` and `second-boot`, and `all` is every scenario. The last three check the image for their entrypoint. `snapshot-restore` and `factory-reset` fail once an image ships theirs, until they are automated, so they can never pass without having run.

## Run it

Run on an aarch64 Linux host with `/dev/kvm`, passwordless sudo (loop devices, cryptsetup, mounts, the chroot) and `qemu-system-aarch64`, `dtc` (`fdtput`), `socat`, `gptfdisk`, `dosfstools`, `btrfs-progs`, `cryptsetup`, `mkinitcpio` (for `lsinitcpio`), `libarchive` (`bsdtar`), `gnupg`, `curl` and `python3`:

```bash
tools/acceptance/mac-image/run --image /var/tmp/omarchy-images/<set>/image
tools/acceptance/mac-image/run --image DIR --scenario password-change
tools/acceptance/mac-image/run --payload omarchy-<date>-aarch64-apple-silicon-mac-edge-os-package.zip
```

`--image` takes the producer's output directory. `IMAGE` must be format 2 for `apple-silicon`, and `PROVENANCE` must agree with the payload's size and digest, with `INSPECTION`, `installer_data.json` and the inputs record. `INSPECTION` must have passed, and every unpacked member must match the digest `IMAGE` lists. `IMAGE.sig`, when present, must verify with the repository key (`tools/acceptance/keys/omarchy-arm-repository.asc`, or `OMARCHY_VM_IMAGE_KEY_FILE`); `run.txt` records whether the image was signed. A bare `--payload` is not verified. A published image goes through the same path: download its assets into a directory and pass that.

A run takes about an hour for `fresh-install`; `update` downloads what the image's repositories have published since it was built, and each of its waits lasts up to `OMARCHY_VM_IMAGE_UPDATE_TIMEOUT` seconds (3600). It needs about 60 GB: the unpacked payload, and a 35 GiB disk per scenario (sparse, and a reflink of the conversion disk where the host filesystem has them). Check for 10 GiB free afterwards, since updates on the host refuse below that. `--keep` retains the run directory (`~/vm-mac-image/runs/<run-id>`), and a failed run keeps it too: delete it when done.

Evidence goes to `~/vm-evidence/mac-image-<run-id>/`:

- `run.txt`: the `ok`, `not ok` and `skip` lines, the image identity (candidate set, source and builder commits, package set and input digests, signature), the generic kernel and this harness's commit
- each boot's serial log and command line, and the mkinitcpio log
- the guest's first-boot and owner-setup logs
- `SHA256SUMS`

Passwords and the recovery key are random per run and redacted from the evidence. A kept run directory still holds them as passphrase files, so a failed run can be inspected.

## How the guest stands in for a Mac

- **Kernel and firmware:** the Aurora kernel cannot run on QEMU's `virt` machine (no PL011 console, no generic PCI host, no ACPI). The guest boots a generic Arch Linux ARM `linux-aarch64` kernel from the dated snapshot instead, through UEFI as a Mac boots through U-Boot's: the image's boot tooling builds its UKI only under UEFI. The firmware is Arch Linux's `edk2-aarch64` from the permanent archive, pinned by digest (`OMARCHY_VM_UEFI_URL` and `OMARCHY_VM_UEFI_SHA256` override both). Its initramfs is built inside the image's own root from the image's own mkinitcpio configuration, so the `asahi`, `omarchy-vendorfw`, `omarchy-mac-encrypt`, `sd-encrypt` and `plymouth` hooks under test are the image's. What the image writes to the ESP (its UKI and Limine menu) is what the next boot's command line comes from, but the guest never runs Limine, m1n1 or U-Boot.
- **Device tree:** QEMU's own `virt` device tree gets an Apple root compatible (`apple,j314s`, `apple,t6000`, `apple,arm-platform`) and model. The image's detectors then take their Apple paths: the Limine rebuild after conversion, the deferred Limine step, and the Apple re-key with its recovery key.
- **Console:** the guest has no display. Owner setup asks on tty1, so two credential drop-ins on the kernel command line move it to the serial console and order the serial login after it. The harness answers setup there as an owner would, keeping every default. The disk password prompt appears on the serial console with Plymouth disabled (`plymouth.enable=0`).
- **Checks:** the harness stops a guest after the writeback interval rather than shutting it down, then checks its disk offline. The disk is attached read-write and mounted read-only, so the kernel replays the journals.

Physical hardware (GPU, audio, Wi-Fi, suspend, the boot chain before the kernel) is qualified on the M1 Pro and the M2 Max; a VM pass never substitutes for it. The guest's disks are addressed by device path, never by the image's fixed UUIDs, so the harness also runs on a Mac that was itself installed from an image. While a run lasts, a transient udev rule hides every loop device, and the run's LUKS mappers, from desktop automounters, which would otherwise mount them and ask the Mac's owner for a password. The chroot that builds the initramfs mounts in a private mount namespace, so none of its mounts reach the host's services.
