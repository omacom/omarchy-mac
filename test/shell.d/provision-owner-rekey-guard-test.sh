#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

provision_owner="$ROOT/bin/omarchy-provision-owner"
eval "$(sed -n '/^owner_auto_unlock_pending() {/,/^}/p; /^owner_rekey_pending() {/,/^}/p' "$provision_owner")"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
provisioning_dir="$test_tmp/var/lib/omarchy/provisioning"
system_root="$test_tmp/root"
mkdir -p "$provisioning_dir" "$system_root/etc"

if owner_rekey_pending "$provisioning_dir" "$system_root"; then
  fail 'clean provisioning state is not re-key pending'
fi

artifacts=(
  "$provisioning_dir/luks-key"
  "$provisioning_dir/owner-rekey"
  "$system_root/etc/omarchy/provisioning.key"
  "$system_root/etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf"
  "$system_root/etc/default/grub.d/99-omarchy-provisioning-unlock.cfg"
  "$system_root/etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf"
)

for artifact in "${artifacts[@]}"; do
  mkdir -p "$(dirname "$artifact")"
  : >"$artifact"
  owner_rekey_pending "$provisioning_dir" "$system_root" ||
    fail "auto-unlock artifact remains pending: $artifact"
  rm -f "$artifact"

  ln -s /missing-auto-unlock-target "$artifact"
  owner_rekey_pending "$provisioning_dir" "$system_root" ||
    fail "dangling auto-unlock link remains pending: $artifact"
  rm -f "$artifact"
done

mkdir -p "$provisioning_dir/owner-rekey"
owner_rekey_pending "$provisioning_dir" "$system_root" ||
  fail 'an owner re-key receipt remains pending'
owner_auto_unlock_pending "$provisioning_dir" "$system_root" &&
  fail 'a receipt alone is not an auto-unlock artifact'
rmdir "$provisioning_dir/owner-rekey"

grep -q 'staged_key=/etc/omarchy/provisioning.key' "$provision_owner" ||
  fail 'installed provisioning key can resume owner re-keying'
grep -q '^  if owner_rekey_pending; then$' "$provision_owner" ||
  fail 'owner provisioning gates completion on every auto-unlock artifact'
grep -q '^  ! owner_auto_unlock_pending || return 1$' "$provision_owner" ||
  fail 'owner provisioning verifies cleanup after a completed receipt'

pass 'owner provisioning detects files and dangling links for every auto-unlock artifact'
