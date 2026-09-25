# Apple boot support

This subtree is built into `omarchy-mac-boot`, separately from the kernel-neutral `omarchy-mac` hardware package. `../install` intentionally does not stage this directory. The boot recipe owns the initramfs/first-boot payload in the package repository and stages this subtree from the same pinned runtime revision as the desktop candidate.

`install DESTDIR` stages commands in `/usr/bin` and sourced modules/setup leaves in `/usr/lib/omarchy-mac/boot`. It performs no live setup. `test/all` runs disposable command fixtures; shared provisioning/reset integration remains covered by the runtime suite.

The implementation was moved from runtime integration `e82fe3c8850b184dfa22eefd571646ad85446122`, preserving Marcelo's provenance recorded in the runtime source-port ledger. The owner wizard, recovery-slot operations, journal/retry handling and shared Limine menu/hash operations remain core code. Provisioning and reset refuse to proceed on Apple Silicon when their required package module is unavailable.

## Temporary adaptations

- Deploy ARM64 Limine to U-Boot's `EFI/BOOT/BOOTAA64.EFI` slot until the shared Limine installer supports that target.
- Retain the current GRUB-defaults-to-`rd.luks.*` command-line bridge while conversion, rekey and reset share that protocol. Switching to Limine does not itself change the initramfs unlock protocol. Removing this bridge requires coordinated conversion/rekey/reset qualification.
- Check factory-kernel coherence against the live boot partition because firmware, m1n1/U-Boot and DTBs are outside root snapshots. Generic root snapshot restoration alone cannot establish boot compatibility.

Do not duplicate shared snapshot/UI/password policy here. Historical GRUB fallback remains for compatibility; this refactor qualifies fresh Limine images, not upgrades of old factory snapshots. Old-quattro migration is separately designed and tested.
