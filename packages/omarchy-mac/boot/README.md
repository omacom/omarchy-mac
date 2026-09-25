# Apple boot support

This subtree is built into `omarchy-mac-boot`, separately from the kernel-neutral `omarchy-mac` hardware package. `../install` intentionally does not stage this directory. The boot recipe pins a runtime revision, the same one as the desktop candidate, and stages this subtree from it; the recipe keeps only packaging metadata and the pacman scriptlet.

`install DESTDIR` stages commands in `/usr/bin`, sourced modules/setup leaves in `/usr/lib/omarchy-mac/boot`, and the initramfs, in-place encryption and first-boot payload in `files/` at its installed paths (mkinitcpio drop-ins, initcpio hooks, units, presets, the ALPM hook and `/etc/default/update-m1n1`, which pins update-m1n1's device-tree order to the C locale). It performs no live setup. The recipe's `backup=` covers every `files/etc` path and `files/usr/lib/omarchy/initcpio`. `test/all` runs command fixtures and the payload's offline checks; `OMARCHY_DISPOSABLE_BOOT_TESTS=1` also builds real initramfs images and converts loop-device disks in privileged containers. Shared provisioning/reset integration remains covered by the runtime suite.

The implementation was moved from runtime integration `e82fe3c8850b184dfa22eefd571646ad85446122`, preserving Marcelo's provenance recorded in the runtime source-port ledger. The payload in `files/` comes from the boot recipe paired with #503 (omarchy-mac/omarchy-pkgs-aarch64#65 at `617a907f99a1`) with maralcbr/omarchy-pkgs#202 applied (omarchy-mac-boot 20260921-10: the owner's keyboard layout and dock keyboards at the disk prompt). The owner wizard, recovery-slot operations, journal/retry handling and shared Limine menu/hash operations remain core code. Owner provisioning and `omarchy-drive-password` reach this package only through `omarchy-lifecycle-dispatch`, which runs the `entrypoints/` staged in `/usr/lib/omarchy/mac-boot` and fails on Apple Silicon when they are missing; factory reset still refuses to proceed when its module is unavailable.

## Temporary adaptations

- Deploy ARM64 Limine to U-Boot's `EFI/BOOT/BOOTAA64.EFI` slot until the shared Limine installer supports that target.
- Retain the current GRUB-defaults-to-`rd.luks.*` command-line bridge while conversion, rekey and reset share that protocol. Switching to Limine does not itself change the initramfs unlock protocol. Removing this bridge requires coordinated conversion/rekey/reset qualification.
- Check factory-kernel coherence against the live boot partition because firmware, m1n1/U-Boot and DTBs are outside root snapshots. Generic root snapshot restoration alone cannot establish boot compatibility.

Do not duplicate shared snapshot/UI/password policy here. Historical GRUB fallback remains for compatibility; this refactor qualifies fresh Limine images, not upgrades of old factory snapshots. Old-quattro migration is separately designed and tested.
