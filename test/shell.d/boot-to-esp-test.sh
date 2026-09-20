#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture_root_uuid=01234567-89ab-cdef-0123-456789abcdef

run_guard() (
  fixture=$1
  source "$ROOT/bin/omarchy-system-boot-to-esp"
  findmnt() {
    [[ $* == "-nro UUID --target $work/$fixture" ]] || return 99
    printf '%s\n' "${fixture_uuid-$fixture_root_uuid}"
    return "${fixture_status:-0}"
  }
  refuse_iso_boot_layout "$work/$fixture"
)

expect_refusal() {
  local fixture=$1 expected=$2 output
  if output=$(run_guard "$fixture" 2>&1); then
    fail "$fixture refuses migration"
  fi
  [[ $output == *"$expected"* ]] || fail "$fixture explains the refusal" "$output"
  pass "$fixture refuses migration"
}

mkdir -p "$work/marker/etc"
touch "$work/marker/etc/omarchy-mac-iso-shared-esp"
expect_refusal marker 'shares its EFI partition'

mkdir -p "$work/private/boot/efi/EFI/omarchy/$fixture_root_uuid"
expect_refusal private 'UUID-private EFI boot files'

mkdir -p "$work/boot-mounted/boot/EFI/omarchy/$fixture_root_uuid"
expect_refusal boot-mounted 'UUID-private EFI boot files'

mkdir -p "$work/config-only/boot/efi/grub/omarchy-roots"
touch "$work/config-only/boot/efi/grub/omarchy-roots/$fixture_root_uuid.cfg"
expect_refusal config-only 'UUID-private EFI boot files'

mkdir -p "$work/other-root/boot/efi/EFI/omarchy/11111111-2222-3333-4444-555555555555"
run_guard other-root || fail 'another root UUID does not block an ordinary installation'
pass 'another root UUID does not block an ordinary installation'

mkdir -p "$work/normal/boot/efi/EFI/BOOT" "$work/normal/boot/grub"
run_guard normal || fail 'ordinary Asahi layout remains supported'
pass 'ordinary Asahi layout remains supported'

fixture_status=1 expect_refusal private 'cannot identify the root filesystem UUID'
fixture_uuid='' expect_refusal private 'cannot identify the root filesystem UUID'
fixture_uuid='../bad' expect_refusal private 'cannot identify the root filesystem UUID'

# Run the real main entrypoint with only its filesystem fixture redirected.
# Protected layouts must stop before either the no-op mount check or writes.
for fixture in marker private; do
  before=$(find "$work/$fixture" -printf '%P %y\n' | sort)
  if output=$( {
    source "$ROOT/bin/omarchy-system-boot-to-esp"
    eval "$(declare -f refuse_iso_boot_layout | sed '1s/refuse_iso_boot_layout/fixture_guard/')"
    refuse_iso_boot_layout() { fixture_guard "$work/$fixture"; }
    findmnt() { printf '%s\n' "$fixture_root_uuid"; }
    uname() { printf 'aarch64\n'; }
    for command in mount umount mkdir rmdir cp mv grub-install grub-mkconfig mkinitcpio; do
      eval "$command() { printf '%s\\n' '$command' >> '$work/mutations'; return 99; }"
    done
    main --yes
  } 2>&1); then
    fail "$fixture main must refuse even with --yes"
  fi
  [[ $output == *'this ISO installation'* ]] || fail "$fixture main reaches the protection guard" "$output"
  [[ ! -e $work/mutations ]] || fail "$fixture main performs no mutation"
  after=$(find "$work/$fixture" -printf '%P %y\n' | sort)
  [[ $before == "$after" ]] || fail "$fixture boot files remain unchanged"
  pass "$fixture main refuses before writes, even with --yes"
done
