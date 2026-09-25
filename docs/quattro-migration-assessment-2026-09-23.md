# Quattro migration compatibility assessment

Migration source: `omacom/omarchy-mac:quattro` at `90438bceab9601b0181e65bc47180d1fb1d34496`, read from GitHub on September 23, 2026. Target baseline: tested integration `e82fe3c8850b184dfa22eefd571646ad85446122`, based on `quattro-upstream` at `1c595bb6030c487c0b584f3e192ef9e8b858b821`. Other local refs named quattro are not interchangeable with this source.

The intended future migration is in place, preserving accounts, installed applications, settings and data. Backup/reinstall is a fallback. This assessment introduces no migration script, repository-trust change, channel enablement or support claim.

## Constraints on the current refactor

- The source already implements a staged ARM update transaction in `install/helpers/arm-channel.sh` and its channel/update entrypoints. It preflights the desktop/settings pair, package plan and signatures in a private keyring, and switches migration execution to the newly installed source. The target's empty qualified-channel list is a target restriction, not a description of existing users. Do not replace the source transaction without qualifying equivalent safeguards.
- Inventory actual installed repository configuration and trusted signers. The source template includes an edge aarch64 feed with `Optional TrustAll` and selected official edge packages; local installations may differ. Do not copy target templates over this configuration or silently change trust. Pilot candidate packages are not an established migration channel.
- The source owns microphone/Wi-Fi commands and user units in the desktop. Transfer them to `omarchy-mac`, and boot helpers to `omarchy-mac-boot`, in a coordinated package transaction with exactly one owner per path. Inspect both `/usr/bin` and desktop-source `bin` paths for collisions and stale shadowing. Never use wildcard package overwrite to hide errors. New artifacts must receive new versions/releases.
- Preserve the boot package's provides/conflicts/replaces for `omarchy-apple-boot` and `omarchy-first-boot`, pending-marker transfer, distinct initcpio/drop-in paths and administrator `.pacsave` handling. Preserve the hardware package's exact-generated-file retirement backups, overrides/masks, explicit disable markers and microphone gain settings. Do not wholesale refresh user configuration.
- Inventory recorded migration history: migrations differ across the branches. Test from a real source installation with history, rather than treating new-owner setup as migration coverage.
- Inventory existing Mac snapshot/restore configuration and custom setup behavior. The old Mac snapshot backend is replaced by shared restore tooling in the target. Old snapshots and factory roots can contain old desktop-owned commands and no boot package; the running root cannot supply those implicitly to a chroot. Firmware and kernel coherence checks remain required.

## Future qualification outline

1. Capture installed package manifests, versions, signatures, repository configuration, migration history, bootloader/kernel family, partition layout, factory/snapshot inventory and configuration overrides without collecting credentials.
2. Prepare a signed, pinned upgrade transaction; prove compatible package resolution, simultaneous ownership transfer, configuration retention and an explicit rollback/recovery path before activation.
3. Test representative old-quattro systems, including GRUB and existing Limine where present, with user settings and package additions retained. Test interrupted transaction/retry behavior and migration history idempotence.
4. Qualify normal updates, reboot/unlock, snapshot restore and factory-reset compatibility separately from fresh-image installation. Only then enable a supported channel transition.

Fresh Limine installation and migration remain separate qualification tracks. The small pilot stays explicitly frozen; current instructions to avoid normal updates remain in force.
