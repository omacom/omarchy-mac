#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

reset="$ROOT/bin/omarchy-system-factory-reset"
owner="$ROOT/bin/omarchy-provision-owner"
rebuild="$ROOT/bin/omarchy-boot-rebuild"

[[ -x $rebuild ]] || fail "omarchy-boot-rebuild is an executable"
grep -qF '# omarchy:hidden=true' "$rebuild" || fail "omarchy-boot-rebuild is hidden"
grep -qF '# omarchy:requires-sudo=true' "$rebuild" || fail "omarchy-boot-rebuild requires sudo"
grep -qF 'omarchy-cmd-present limine' "$rebuild" ||
  fail "omarchy-boot-rebuild detects Limine via the limine binary, not limine-update"
grep -qF 'omarchy-cmd-present grub-mkconfig' "$rebuild" ||
  fail "omarchy-boot-rebuild falls back to GRUB when Limine is absent"
pass "omarchy-boot-rebuild is a hidden Limine-or-GRUB helper"

grep -qF 'factory_uses_limine' "$reset" || fail "factory reset distinguishes Limine factory snapshots"
grep -qF 'install_boot_rebuild_into_next' "$reset" ||
  fail "factory reset copies omarchy-boot-rebuild into the staged clone"
grep -qF 'omarchy-system-factory-reset omarchy-provision-owner' "$reset" ||
  fail "factory reset copies the live reset tools into the staged clone so a later reset still works"
grep -qF 'verify_grub_provisioning_boot' "$reset" ||
  fail "factory reset verifies the GRUB provisioning boot files"
grep -qF 'usr/bin/grub-mkconfig' "$reset" || fail "factory reset has a GRUB rebuild path"
grep -qF '/usr/bin/omarchy-boot-rebuild' "$reset" ||
  fail "factory reset chroots into omarchy-boot-rebuild on GRUB"
grep -qF 'generate_grub_cfg_from_factory' "$reset" ||
  fail "factory reset writes grub.cfg on the host when grub-probe cannot map / in chroot"
grep -qF 'if [[ -x $root/usr/bin/limine ]]; then' "$reset" ||
  fail "missing limine.conf template is fatal only on Limine factory images"
pass "factory reset rebuilds GRUB when the factory snapshot has no Limine"

grep -qF 'rebuild_boot()' "$owner" || fail "provision-owner has a boot-rebuild wrapper"
grep -qF 'omarchy-cmd-present omarchy-boot-rebuild' "$owner" ||
  fail "provision-owner prefers omarchy-boot-rebuild when the helper is staged"
grep -qE '^[[:space:]]*limine-update$' "$owner" ||
  fail "provision-owner still falls back to limine-update for older factory snapshots"
! grep -q 'if ! limine-update' "$owner" ||
  fail "provision-owner no longer calls limine-update directly during re-key"
pass "first-boot LUKS re-key rebuilds via omarchy-boot-rebuild"

docs="$ROOT/docs/btrfs.md"
grep -qF 'cryptkey=rootfs:/etc/omarchy/provisioning.key' "$docs" ||
  fail "btrfs docs describe GRUB cryptkey= auto-unlock"
! grep -qF 'which does not exist on the Mac' "$docs" ||
  fail "btrfs docs no longer claim factory reset skips auto-unlock on GRUB"
pass "btrfs docs describe the GRUB provisioning auto-unlock path"
