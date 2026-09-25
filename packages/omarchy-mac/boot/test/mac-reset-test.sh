#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The factory reset entrypoints omarchy-lifecycle-dispatch runs, staged by
# install into a fixture root and run as the files they are. The live Mac is
# the fixture root; the factory root is a separate clone. chroot runs the
# factory root's own omarchy-mac-boot-update stub, which rebuilds the live boot
# files the way the bind-mounted /boot would receive them.
test_tmp=$(mktemp -d)
trap 'chmod -R u+w "$test_tmp" 2>/dev/null; rm -rf "$test_tmp"' EXIT
root=$test_tmp/root
next=$test_tmp/next
stub_bin=$test_tmp/bin
calls=$test_tmp/calls
mkdir -p "$stub_bin"
bash "$ROOT/install" "$root"
entry=$root/usr/lib/omarchy/mac-boot
reset_dir=$root/run/omarchy-mac-boot/reset

luks_uuid=1b2c3d4e-0000-4000-8000-000000000001
token="rd.luks.key=$luks_uuid=/omarchy/luks-key:UUID=4f4d5801-424f-4f54-8000-000000000001"
old_id=0123456789abcdef0123456789abcdef
new_id=fedcba9876543210fedcba9876543210
other_id=11111111111111111111111111111111
firmware_listing='./usr/lib/systemd/system-generators/systemd-cryptsetup-generator
./usr/lib/systemd/system/omarchy-vendorfw-initrd.service
./usr/lib/systemd/system/systemd-cryptsetup@.service.d/omarchy-vendorfw-initrd.conf'

cat >"$stub_bin/omarchy-hw-platform" <<'SH'
#!/bin/bash
echo "${TEST_PLATFORM:-apple-silicon}"
SH
cat >"$stub_bin/omarchy-mac-kernel" <<'SH'
#!/bin/bash
echo linux-aurora
SH
cat >"$stub_bin/omarchy-mac-esp" <<'SH'
#!/bin/bash
[[ -n ${TEST_ESP-/boot/efi} ]] || exit 1
echo "${TEST_ESP-/boot/efi}"
SH
cat >"$stub_bin/findmnt" <<'SH'
#!/bin/bash
if [[ " $* " == *" --mountpoint "* && " $* " == *" UUID "* && ${*: -1} == */boot ]]; then
  echo "${TEST_BOOT_UUID-4f4d5801-424f-4f54-8000-000000000001}"
  exit 0
fi
exec /usr/bin/findmnt "$@"
SH
cat >"$stub_bin/lsinitcpio" <<'SH'
#!/bin/bash
[[ $1 == -l && -f $2 ]] && cat "$2"
SH
cat >"$stub_bin/cryptsetup" <<SH
#!/bin/bash
echo "cryptsetup \$*" >>"$calls"
[[ \$1 == luksUUID && -e \$2 ]] && { echo $luks_uuid; exit 0; }
exit 1
SH
for tool in mount umount update-grub update-m1n1; do
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$tool" "$calls" >"$stub_bin/$tool"
done
# chroot runs a command in the factory root: an absolute path is the factory
# root's own file, anything else a stub on PATH.
cat >"$stub_bin/chroot" <<SH
#!/bin/bash
echo "chroot \$*" >>"$calls"
factory=\$1
shift
[[ \$1 != /* ]] || set -- "\$factory\$1" "\${@:2}"
exec "\$@"
SH
cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
echo "mkinitcpio \$*" >>"$calls"
[[ ! -e $test_tmp/fail-mkinitcpio ]] || { printf 'broken' >"$root/boot/initramfs-linux-aurora.img"; exit 1; }
if [[ -e $test_tmp/build-without-firmware ]]; then
  echo ./usr/lib/systemd/system-generators/systemd-cryptsetup-generator >"$root/boot/initramfs-linux-aurora.img"
else
  printf '%s\n' "$firmware_listing" >"$root/boot/initramfs-linux-aurora.img"
fi
printf 'fallback' >"$root/boot/initramfs-linux-aurora-fallback.img"
SH
# Bare sync flushes the rebuild; sync with a file flushes encrypt.state or the
# key.
cat >"$stub_bin/sync" <<SH
#!/bin/bash
if (( \$# == 0 )); then [[ ! -e $test_tmp/fail-sync-rebuild ]] || exit 1
elif [[ \$* == *encrypt.state* ]]; then [[ ! -e $test_tmp/fail-sync-state ]] || exit 1
elif [[ \$* == *luks-key* ]]; then [[ ! -e $test_tmp/fail-sync-key ]] || exit 1
fi
exec /usr/bin/sync "\$@"
SH
cat >"$stub_bin/cp" <<'SH'
#!/bin/bash
last=${!#}
[[ -n ${TEST_NO_STAGE:-} && $last == *.omarchy-restore ]] && exit 1
[[ -n ${TEST_NO_UKI_RESTORE:-} && $last == */EFI/Linux ]] && exit 1
exec /usr/bin/cp "$@"
SH
chmod +x "$stub_bin"/*

# The factory root's boot rebuild: GRUB, or on a Limine factory root the
# command line, a new UKI and an entry for its machine-id with the UKI's hash.
factory_boot_update() {
  mkdir -p "$next/usr/bin"
  cat >"$next/usr/bin/omarchy-mac-boot-update" <<SH
#!/bin/bash
cmdline=\$(sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"/\1/p' "$next/etc/default/grub")
echo "omarchy-mac-boot-update \$cmdline" >>"$calls"
[[ ! -e $test_tmp/fail-boot-update ]] || exit 1
esp=$root\${TEST_ESP-/boot/efi}
if [[ -e $next/var/lib/omarchy/limine.enabled ]]; then
  printf 'ESP_PATH="%s"\nKERNEL_CMDLINE[default]="%s"\n' "\${TEST_ESP-/boot/efi}" "\$cmdline" >"$next/etc/default/limine"
  mkdir -p "\$esp/EFI/Linux" "\$esp/EFI/BOOT"
  printf 'new uki' >"\$esp/EFI/Linux/omarchy_linux-aurora.efi"
  printf 'new limine' >"\$esp/EFI/BOOT/BOOTAA64.EFI"
  hash=\$(b2sum "\$esp/EFI/Linux/omarchy_linux-aurora.efi" | cut -d' ' -f1)
  printf '/+Omarchy\ncomment: machine-id=%s order-priority=50\n  //linux-aurora\n  path: boot():/EFI/Linux/omarchy_linux-aurora.efi#%s\n' \\
    "\$(cat "$next/etc/machine-id")" "\$hash" >>"\$esp/limine.conf"
else
  printf 'linux /vmlinuz-linux-aurora %s\n' "\$cmdline" >"$root/boot/grub/grub.cfg"
fi
SH
  chmod +x "$next/usr/bin/omarchy-mac-boot-update"
}

# A GRUB Mac whose previous owner finished encryption, and a factory root
# snapshotted before the first boot encrypted it, carrying the same kernel.
fixture() {
  chmod -R u+w "$root/boot" "$root/etc" "$root/var" "$root/run" "$next" 2>/dev/null || true
  rm -rf "${root:?}"/{boot,etc,var,run,dev,proc,sys} "$next"
  mkdir -p "$root/boot/omarchy" "$root/boot/grub" "$root/boot/efi/EFI/BOOT" "$root/etc/default" \
    "$root/var/lib/omarchy/mac-first-boot" "$root/dev" "$root/proc" "$root/sys" "$root/run" \
    "$next/usr/lib/modules/7.1-aurora" "$next/etc/default" "$next/usr/share/omarchy/default/limine"
  printf 'kernel' >"$root/boot/vmlinuz-linux-aurora"
  printf 'kernel' >"$next/usr/lib/modules/7.1-aurora/vmlinuz"
  echo linux-aurora >"$next/usr/lib/modules/7.1-aurora/pkgbase"
  printf '%s\n' "$firmware_listing" >"$root/boot/initramfs-linux-aurora.img"
  printf 'old fallback' >"$root/boot/initramfs-linux-aurora-fallback.img"
  printf 'linux /vmlinuz-linux-aurora quiet rd.luks.name=%s=root\n' "$luks_uuid" >"$root/boot/grub/grub.cfg"
  printf 'grub' >"$root/boot/efi/EFI/BOOT/BOOTAA64.EFI"
  printf 'format=1\nphase=finished\npartition=5f2b0c3e-0003\nluks_uuid=%s\nowner_slot=1\nrecovery_slot=2\n' "$luks_uuid" \
    >"$root/boot/omarchy/encrypt.state"
  printf 'GRUB_CMDLINE_LINUX="quiet rd.luks.name=%s=root"\nGRUB_CMDLINE_LINUX_DEFAULT="splash"\n' "$luks_uuid" >"$root/etc/default/grub"
  printf 'root UUID=%s none luks\n' "$luks_uuid" >"$root/etc/crypttab"
  printf 'format=1\nencrypt=1\n' >"$root/var/lib/omarchy/mac-first-boot/install.conf"
  : >"$root/dev/luks"
  printf 'GRUB_CMDLINE_LINUX="quiet"\n' >"$next/etc/default/grub"
  echo "$new_id" >"$next/etc/machine-id"
  printf 'timeout: 3\n' >"$next/usr/share/omarchy/default/limine/limine.conf"
  factory_boot_update
  rm -f "$test_tmp"/fail-* "$test_tmp/build-without-firmware"
  : >"$calls"
}

# The same Mac booting Limine from the ESP at /boot/efi, with the previous
# identity's history and another installation's directory on the ESP.
limine_fixture() {
  fixture
  local esp=$root/boot/efi
  mkdir -p "$esp/EFI/Linux" "$esp/$old_id" "$esp/$other_id" "$root/var/lib/omarchy" "$next/var/lib/omarchy"
  printf 'old uki' >"$esp/EFI/Linux/omarchy_linux-aurora.efi"
  printf 'old limine' >"$esp/EFI/BOOT/BOOTAA64.EFI"
  printf 'history' >"$esp/$old_id/limine_history"
  printf 'other' >"$esp/$other_id/limine_history"
  printf 'timeout: 3\n# path: boot():/EFI/Linux/removed.efi#0123abcd\n/+Omarchy\ncomment: machine-id=%s\n  //linux-aurora\n  path: boot():/EFI/Linux/omarchy_linux-aurora.efi#%s\n' \
    "$old_id" "$(b2sum "$esp/EFI/Linux/omarchy_linux-aurora.efi" | cut -d' ' -f1)" >"$esp/limine.conf"
  : >"$root/var/lib/omarchy/limine.enabled"
  printf 'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]="root=UUID=x rw quiet rd.luks.name=%s=root"\n' "$luks_uuid" >"$root/etc/default/limine"
  : >"$next/var/lib/omarchy/limine.enabled"
  printf 'ESP_PATH="/boot/efi"\n' >"$next/etc/default/limine"
}

run() {
  OMARCHY_MAC_BOOT_ROOT=$root PATH="$stub_bin:$PATH" "$entry/$1" "${@:2}" 2>"$test_tmp/err"
}

boot_tree() {
  (cd "$root/boot" && find . -type f -exec sha256sum {} + | sort)
}

error_says() {
  grep -Fq "$1" "$test_tmp/err" || fail "the error says: $1" "$(cat "$test_tmp/err")"
}

for name in reset-prepare reset-verify reset-commit reset-rollback; do
  [[ -x $entry/$name && $(head -n 1 "$entry/$name") == "#!/bin/bash -p" ]] ||
    fail "$name is an executable entrypoint that ignores BASH_ENV"
done

fixture
before=$(boot_tree)
for platform in generic-aarch64 qualcomm generic; do
  if TEST_PLATFORM=$platform run reset-prepare "$next" "$root/dev/luks"; then fail "reset-prepare refuses to run on $platform"; fi
  error_says "runs only on Apple Silicon"
  for name in reset-commit reset-rollback; do
    if TEST_PLATFORM=$platform run "$name" </dev/null; then fail "$name refuses to run on $platform"; fi
  done
  if TEST_PLATFORM=$platform run reset-verify "$next"; then fail "reset-verify refuses to run on $platform"; fi
done
[[ $(boot_tree) == "$before" && ! -s $calls && ! -e $reset_dir ]] || fail "nothing changes off Apple Silicon"
pass "every reset entrypoint re-checks the platform and refuses off Apple Silicon"

# ── An encrypted GRUB Mac: prepare, verify, commit ─────────────────────────
fixture
before=$(boot_tree)
run reset-prepare "$next" "$root/dev/luks" || fail "reset-prepare stages an encrypted GRUB Mac" "$(cat "$test_tmp/err")"
[[ $(cat "$next/etc/crypttab") == "root UUID=$luks_uuid none luks" ]] || fail "the factory root gets the live crypttab"
grep -Fxq "GRUB_CMDLINE_LINUX=\"quiet rd.luks.name=$luks_uuid=root $token\"" "$next/etc/default/grub" ||
  fail "the factory root's GRUB defaults are the live ones with the unlock added" "$(cat "$next/etc/default/grub")"
grep -Fq "linux /vmlinuz-linux-aurora quiet rd.luks.name=$luks_uuid=root $token" "$root/boot/grub/grub.cfg" ||
  fail "grub.cfg is rebuilt from the factory root's command line" "$(cat "$root/boot/grub/grub.cfg")"
grep -q '^chroot .* mkinitcpio -P$' "$calls" && grep -q "^chroot $next /usr/bin/omarchy-mac-boot-update\$" "$calls" ||
  fail "the initramfs and boot loader are rebuilt inside the factory root" "$(cat "$calls")"
! grep -q 'update-m1n1' "$calls" || fail "a reset leaves m1n1 and its device trees alone"
grep -q "^umount -R $next/proc" "$calls" || fail "the factory root's bind mounts go after the rebuild" "$(cat "$calls")"
[[ $(cat "$root/boot/omarchy/encrypt.state") == $'format=1\nphase=configured\npartition=5f2b0c3e-0003\nluks_uuid='"$luks_uuid" ]] ||
  fail "encrypt.state is reopened for the next owner without the previous slots" "$(cat "$root/boot/omarchy/encrypt.state")"
[[ ! -e $root/boot/omarchy/luks-key ]] || fail "reset-prepare writes no key"
run reset-verify "$next" || fail "the rebuilt boot files boot the factory root" "$(cat "$test_tmp/err")"
state_after_verify=$(boot_tree)
key=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
printf '%s' "$key" | run reset-commit || fail "reset-commit writes the unlock key" "$(cat "$test_tmp/err")"
[[ $(cat "$root/boot/omarchy/luks-key") == "$key" && $(stat -c '%a' "$root/boot/omarchy/luks-key") == 600 ]] ||
  fail "the Boot partition key is the throwaway from standard input, mode 600"
! compgen -G "$root/boot/omarchy/luks-key.*" >/dev/null || fail "no staged key is left beside it"
[[ ! -e $reset_dir ]] || fail "commit drops the saved boot files"
[[ $state_after_verify != "$before" ]] || fail "the reset rebuilt the boot files"
pass "an encrypted reset stages the unlock, rebuilds in the factory root, reopens encrypt.state and writes the key only at commit"

# Verification is read-only and fails for every boot-chain gap.
fixture
run reset-prepare "$next" "$root/dev/luks" || fail "prepare" "$(cat "$test_tmp/err")"
snapshot_before=$(boot_tree)
: >"$calls"
run reset-verify "$next" || fail "verify passes" "$(cat "$test_tmp/err")"
[[ $(boot_tree) == "$snapshot_before" && ! -s $calls ]] || fail "reset-verify changes nothing and runs no rebuild"
echo ./usr/lib/systemd/system-generators/systemd-cryptsetup-generator >"$root/boot/initramfs-linux-aurora.img"
if run reset-verify "$next"; then fail "an initramfs asking for the password before the keyboard firmware fails"; fi
error_says "before the keyboard firmware loads"
printf '%s\n' "$firmware_listing" >"$root/boot/initramfs-linux-aurora.img"
sed -i "s| $token||" "$root/boot/grub/grub.cfg"
if run reset-verify "$next"; then fail "a grub.cfg without the unlock fails"; fi
error_says "grub.cfg does not unlock"
printf 'other kernel' >"$next/usr/lib/modules/7.1-aurora/vmlinuz"
if run reset-verify "$next"; then fail "a factory kernel that differs from /boot fails"; fi
error_says "kernel differs"
run reset-rollback || fail "rollback" "$(cat "$test_tmp/err")"
if run reset-verify "$next"; then fail "nothing prepared fails verification"; fi
error_says "No factory reset is prepared"
pass "reset-verify is read-only and refuses firmware ordering, a missing unlock, kernel drift and an unprepared reset"

# ── Rollback ──────────────────────────────────────────────────────────────
fixture
before=$(boot_tree)
state_before=$(cat "$root/boot/omarchy/encrypt.state")
run reset-prepare "$next" "$root/dev/luks" || fail "prepare" "$(cat "$test_tmp/err")"
[[ $(boot_tree) != "$before" ]] || fail "prepare changed the live boot files"
run reset-rollback || fail "rollback succeeds" "$(cat "$test_tmp/err")"
[[ $(boot_tree) == "$before" ]] || fail "rollback restores every live boot file" "$(diff <(echo "$before") <(boot_tree))"
[[ $(cat "$root/boot/omarchy/encrypt.state") == "$state_before" ]] || fail "rollback restores the finished encrypt.state"
[[ ! -e $reset_dir ]] || fail "a complete rollback drops the saved copies"
run reset-rollback || fail "a rollback with nothing prepared is a success"
pass "reset-rollback puts the boot files and encrypt.state back exactly"

# A failed rebuild or flush leaves the previous files for rollback to restore.
for failure in fail-mkinitcpio fail-boot-update fail-sync-rebuild; do
  fixture
  before=$(boot_tree)
  : >"$test_tmp/$failure"
  if run reset-prepare "$next" "$root/dev/luks"; then fail "prepare fails with $failure"; fi
  grep -q '^chroot .* mkinitcpio' "$calls" || fail "$failure comes during the rebuild"
  grep -q "^umount -R $next/proc" "$calls" || fail "$failure still unmounts the factory root" "$(cat "$calls")"
  run reset-rollback || fail "rollback after $failure" "$(cat "$test_tmp/err")"
  [[ $(boot_tree) == "$before" ]] || fail "$failure: rollback restores every live boot file" "$(diff <(echo "$before") <(boot_tree))"
done
pass "a failed rebuild or flush fails prepare, and rollback restores the previous boot files"

# encrypt.state must be durable before the caller adds the throwaway slot.
fixture
state_before=$(cat "$root/boot/omarchy/encrypt.state")
: >"$test_tmp/fail-sync-state"
if run reset-prepare "$next" "$root/dev/luks"; then fail "prepare fails when the reopened phase cannot be persisted"; fi
error_says "Could not reopen the disk encryption state"
rm "$test_tmp/fail-sync-state"
run reset-rollback || fail "rollback" "$(cat "$test_tmp/err")"
[[ $(cat "$root/boot/omarchy/encrypt.state") == "$state_before" ]] || fail "rollback keeps the finished state"
pass "reset-prepare persists the reopened phase or fails"

# Refusals before anything changes.
fixture
before=$(boot_tree)
printf 'other kernel' >"$next/usr/lib/modules/7.1-aurora/vmlinuz"
if run reset-prepare "$next" "$root/dev/luks"; then fail "a factory kernel that differs from /boot is refused"; fi
error_says "coordinated boot-package restore"
[[ $(boot_tree) == "$before" && ! -e $reset_dir ]] && ! grep -Eq '^(mount|chroot)' "$calls" ||
  fail "a kernel mismatch changes nothing"
fixture
if run reset-prepare /; then fail "the running root is not a factory root"; fi
if run reset-prepare "$test_tmp/missing"; then fail "a missing factory root is refused"; fi
if run reset-prepare "$next" "$root/dev/missing"; then fail "a missing LUKS device is refused"; fi
if TEST_ESP="" run reset-prepare "$next" "$root/dev/luks"; then fail "an unmounted ESP is refused"; fi
error_says "EFI partition this Mac boots from"
if TEST_BOOT_UUID="" run reset-prepare "$next" "$root/dev/luks"; then fail "an image without its Boot partition at /boot is refused"; fi
error_says "Boot partition is not mounted"
[[ $(boot_tree) == "$before" && ! -e $reset_dir ]] && ! grep -Eq '^(mount|chroot|mkinitcpio)' "$calls" ||
  fail "refusals change nothing" "$(cat "$calls")"
mkdir -p "$reset_dir"
if run reset-prepare "$next" "$root/dev/luks"; then fail "a failed reset's saved files block another reset"; fi
error_says "Restart before resetting again"
pass "reset-prepare refuses kernel drift, a bad factory root, device or ESP, and a stale reset before changing anything"

# A backup that cannot complete stops before any boot file changes.
fixture
before=$(boot_tree)
chmod 000 "$root/boot/initramfs-linux-aurora.img"
if run reset-prepare "$next" "$root/dev/luks"; then fail "an incomplete backup fails prepare"; fi
chmod 644 "$root/boot/initramfs-linux-aurora.img"
error_says "Nothing was changed"
! grep -Eq '^(mount|chroot)' "$calls" || fail "an incomplete backup stops before the rebuild" "$(cat "$calls")"
run reset-rollback || fail "rollback after a failed backup" "$(cat "$test_tmp/err")"
[[ $(boot_tree) == "$before" && ! -e $reset_dir ]] || fail "an incomplete backup changes no live file"
pass "an incomplete boot-file backup stops the reset without touching the live files"

# An unencrypted Mac: nothing to unlock, encrypt.state stays, no key.
fixture
printf 'format=1\nphase=declined\npartition=unknown\nluks_uuid=\n' >"$root/boot/omarchy/encrypt.state"
run reset-prepare "$next" || fail "reset-prepare stages an unencrypted Mac" "$(cat "$test_tmp/err")"
[[ ! -e $next/etc/crypttab ]] && ! grep -q 'rd.luks' "$next/etc/default/grub" || fail "no unlock is staged without a LUKS device"
grep -Fxq 'phase=declined' "$root/boot/omarchy/encrypt.state" || fail "a declined encryption stays declined"
run reset-verify "$next" || fail "an unencrypted factory root verifies" "$(cat "$test_tmp/err")"
printf 'unexpected' | run reset-commit || fail "commit" "$(cat "$test_tmp/err")"
[[ ! -e $root/boot/omarchy/luks-key ]] || fail "an unencrypted reset writes no key"
pass "an unencrypted reset stages no unlock and writes no key"

# A key the Boot partition cannot keep is reported, with no leftovers.
fixture
run reset-prepare "$next" "$root/dev/luks" || fail "prepare" "$(cat "$test_tmp/err")"
: >"$test_tmp/fail-sync-key"
if printf 'key' | run reset-commit; then fail "a key that cannot be flushed fails commit"; fi
error_says "the next boot asks for the current disk password once"
[[ ! -e $root/boot/omarchy/luks-key ]] && ! compgen -G "$root/boot/omarchy/luks-key.*" >/dev/null ||
  fail "a failed key write leaves nothing behind"
[[ ! -e $reset_dir ]] || fail "commit drops the saved files even when the key write fails"
fixture
run reset-prepare "$next" "$root/dev/luks" || fail "prepare" "$(cat "$test_tmp/err")"
if run reset-commit </dev/null; then fail "an empty key fails commit"; fi
[[ ! -e $root/boot/omarchy/luks-key ]] || fail "no empty key is written"
pass "reset-commit reports a key it cannot write, and never writes an empty one"

# ── A Limine Mac ──────────────────────────────────────────────────────────
limine_fixture
before=$(boot_tree)
run reset-prepare "$next" "$root/dev/luks" || fail "reset-prepare stages a Limine Mac" "$(cat "$test_tmp/err")"
menu=$root/boot/efi/limine.conf
! grep -q "machine-id=$old_id" "$menu" && grep -q "machine-id=$new_id" "$menu" ||
  fail "the menu starts over from the template with the factory root's entry" "$(cat "$menu")"
[[ ! -e $root/boot/efi/$old_id && -e $root/boot/efi/$other_id ]] ||
  fail "the previous identity's history goes; another installation's stays"
grep -Fq "$token" "$next/etc/default/limine" || fail "the Limine command line carries the unlock"
run reset-verify "$next" || fail "the rebuilt Limine menu boots the factory root" "$(cat "$test_tmp/err")"
printf 'tampered' >"$root/boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
if run reset-verify "$next"; then fail "a UKI that does not match its hash fails"; fi
error_says "does not match its hash"
run reset-rollback || fail "rollback restores a Limine Mac" "$(cat "$test_tmp/err")"
[[ $(boot_tree) == "$before" ]] || fail "rollback restores the menu, UKIs, loader slot and history" "$(diff <(echo "$before") <(boot_tree))"
pass "a Limine Mac's reset starts the menu over, verifies the factory entry's hashes and rolls back whole"

limine_fixture
run reset-prepare "$next" "$root/dev/luks" || fail "prepare" "$(cat "$test_tmp/err")"
sed -i "s/machine-id=$new_id/machine-id=$old_id/" "$menu"
if run reset-verify "$next"; then fail "a menu without the factory root's entry fails"; fi
error_says "does not boot the factory system"
limine_fixture
if TEST_ESP=/boot run reset-prepare "$next" "$root/dev/luks"; then fail "Limine writing to another ESP than the device tree's is refused"; fi
error_says "EFI partition this Mac boots from"
[[ ! -e $reset_dir ]] || fail "an ESP mismatch is refused before anything is saved"
pass "reset-verify needs the factory root's entry, and prepare the ESP Limine writes to"

# The ESP mounted at /boot itself: the menu, UKIs and history live there.
limine_fixture
mv "$root/boot/efi/limine.conf" "$root/boot/efi/EFI" "$root/boot/efi/$old_id" "$root/boot/efi/$other_id" "$root/boot/"
rmdir "$root/boot/efi"
sed -i 's|ESP_PATH="/boot/efi"|ESP_PATH="/boot"|' "$root/etc/default/limine"
before=$(boot_tree)
TEST_ESP=/boot run reset-prepare "$next" "$root/dev/luks" || fail "an ESP at /boot is reset" "$(cat "$test_tmp/err")"
grep -q "machine-id=$new_id" "$root/boot/limine.conf" && [[ ! -e $root/boot/$old_id && -e $root/boot/$other_id ]] ||
  fail "the menu and history on an ESP at /boot start over"
TEST_ESP=/boot run reset-verify "$next" || fail "an ESP at /boot verifies" "$(cat "$test_tmp/err")"
TEST_ESP=/boot run reset-rollback || fail "rollback" "$(cat "$test_tmp/err")"
[[ $(boot_tree) == "$before" ]] || fail "rollback restores an ESP at /boot" "$(diff <(echo "$before") <(boot_tree))"
pass "the ESP omarchy-mac-esp names is the one reset, verified and restored, also at /boot"

# A rebuild that filled the ESP leaves no room to stage: the verified backup
# replaces the rebuilt files directly. If a UKI cannot come back, the old menu
# is not restored over it: the rebuilt menu still matches what is there.
limine_fixture
before=$(boot_tree)
run reset-prepare "$next" "$root/dev/luks" || fail "prepare" "$(cat "$test_tmp/err")"
TEST_NO_STAGE=1 run reset-rollback || fail "rollback without staging room" "$(cat "$test_tmp/err")"
[[ $(boot_tree) == "$before" ]] || fail "without staging room the backup still restores every file"
limine_fixture
run reset-prepare "$next" "$root/dev/luks" || fail "prepare" "$(cat "$test_tmp/err")"
if TEST_NO_STAGE=1 TEST_NO_UKI_RESTORE=1 run reset-rollback; then fail "a UKI that cannot come back fails rollback"; fi
error_says "stay in /run/omarchy-mac-boot/reset"
grep -q "machine-id=$new_id" "$menu" || fail "the old menu is not restored over a UKI that could not be restored"
[[ -d $reset_dir/boot ]] || fail "a partial restore keeps the saved copies"
pass "restoring without staging room works, and a partial restore keeps the rebuilt menu and the copies"

# The saved menu's UKI paths are read the way Limine reads them: any key case,
# the image_path alias, comments ignored, and a path without a hash refused.
probe=$test_tmp/probe
mkdir -p "$probe/EFI/Linux"
printf 'uki' >"$probe/EFI/Linux/a.efi"
good=$(b2sum "$probe/EFI/Linux/a.efi" | cut -d' ' -f1)
probe_menu() {
  printf '%s\n' "$@" >"$probe/limine.conf"
  (
    # shellcheck disable=SC2034 # read by the sourced modules
    MAC_BOOT_ROOT=$root
    source "$root/usr/lib/omarchy-mac/boot/provision.sh"
    source "$root/usr/lib/omarchy-mac/boot/factory-reset.sh"
    menu_matches_ukis "$probe/limine.conf" "$probe"
  )
}
probe_menu "  path: boot():/EFI/Linux/a.efi#$good" "# path: boot():/EFI/Linux/gone.efi#00" ||
  fail "a matching UKI with a commented stale path matches"
for key in PATH Path image_path IMAGE_PATH; do
  if probe_menu "  $key: boot():/EFI/Linux/a.efi#00ff"; then fail "$key: with a stale hash does not match"; fi
done
if probe_menu "  path: boot():/EFI/Linux/a.efi"; then fail "a UKI path without a hash does not match"; fi
pass "menus are checked against every active UKI path form"
