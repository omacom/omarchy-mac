# Mac image first-boot VM

This harness boots a built Mac OS image (the payload the installer app writes
to a Mac: an ESP tree, `boot.img` and `root.img`) in a disposable aarch64 KVM
guest and proves both first boots the app can produce:

- **plain**: `install.conf` with `encrypt=0` on the ESP. The initrd unit records
  the decline, first boot consumes the file, makes this Mac's pacman keyring,
  runs the deferred hardware steps and hands off to owner provisioning.
- **encrypted**: no `install.conf` (the app's default). The initrd unit converts
  the btrfs root to LUKS2 in place with a throwaway key on the Boot partition,
  regenerates GRUB and the initramfs inside the opened root, continues the same
  boot into `/dev/mapper/root` and finishes first boot. A second boot then
  unlocks through sd-encrypt with the key the GRUB cmdline names, ordered after
  the unit.

The Aurora kernel cannot run on QEMU's `virt` machine (no PL011 console, no
generic PCI host, no ACPI). The guest boots a generic Arch Linux ARM
`linux-aarch64` kernel from the dated snapshot instead, with an initramfs built
inside the image's own root from the image's own mkinitcpio configuration, so
the `asahi`, `omarchy-vendorfw`, `omarchy-mac-encrypt` and `sd-encrypt` hooks
under test are the image's. GRUB, m1n1 and the Apple hardware are qualified on
a real Mac; this harness cannot stand in for that.

Run on an aarch64 Linux host with `/dev/kvm`, `qemu-system-aarch64`, `gptfdisk`,
`dosfstools`, `btrfs-progs`, `mkinitcpio` (for `lsinitcpio`) and passwordless
sudo (loop devices, mounts, the chroot):

```bash
test/vm/mac-image/run --release mac-image-10-rc-<digest12>-<sha8>   # a published image
test/vm/mac-image/run --payload omarchy-<date>-aarch64-apple-silicon-mac-rc-os-package.zip
```

A published release is downloaded with `gh`, `IMAGE.sig` is verified with the
repository key (`default/omarchy-arm-repository.asc`), split parts are
reassembled, the payload is held to PROVENANCE's size and digest, and every
unpacked member is held to the digests the signed IMAGE lists. A local
`--payload` build is not verified. `--only plain|encrypted` runs one path,
`--keep` retains the run directory (`~/vm-mac-image/runs/<run-id>`, two sparse
35 GiB disks, the production root size). Evidence goes to `~/vm-evidence/mac-
image-<run-id>/`: `run.txt` with the `ok` lines, payload digest, IMAGE input
digest and generic kernel, the serial log of each boot and the mkinitcpio log.

A failed run keeps its run directory; delete it when done. The guest's disks
are addressed by device path, never by the image's fixed UUIDs, so the harness
also runs on a Mac that was itself installed from an image.
