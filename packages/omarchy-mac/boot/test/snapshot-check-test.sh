#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/test/fixtures/limine-mac.sh"

require_command gzip
require_command b2sum

# limine-snapper-sync runs /etc/boot/hooks/pre.d before it restores a snapshot
# and stops the restore when a hook exits 100 or more. omarchy-mac-snapshot-check
# is that hook on a Mac: the snapshot booted from the Limine menu is restored
# only when it passes the boot check against the boot files outside it.
check=$ROOT/bin/omarchy-mac-snapshot-check
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash "$ROOT/install" "$tmp/stage"
[[ -x $tmp/stage/usr/bin/omarchy-mac-snapshot-check ]] || fail "the package ships omarchy-mac-snapshot-check"
hooks=$tmp/stage/etc/boot/hooks/pre.d
[[ $(readlink "$hooks/04-omarchy-mac-snapshot-check") == /usr/bin/omarchy-mac-snapshot-check ]] ||
  fail "the package links the check into limine-snapper-sync's pre hooks"
[[ $(find "$hooks" -mindepth 1 -printf '%f\n' | LC_ALL=C sort | head -n 1) == 04-omarchy-mac-snapshot-check ]] ||
  fail "the check runs before the Limine activation gate, so a GRUB Mac is told why"
pass "the package installs the restore check as a limine-snapper-sync pre hook"

limine_mac_init "$tmp/mac"
fake=$tmp/bin
mkdir -p "$fake" "$tmp/check-stub"
printf '#!/bin/bash\nexit "${TEST_APPLE:-0}"\n' >"$fake/omarchy-hw-apple-silicon"
printf '#!/bin/bash\nexit 0\n' >"$fake/limine-update"
# pacman -Q lists the snapshot's packages; everything else is the fixture's.
cat >"$fake/pacman" <<SH
#!/bin/bash
if [[ \$* == "-Q" ]]; then
  printf '%s\n' 'linux-aurora 6.17.0.aurora1-1' 'limine 12.9.0-1' 'm1n1-aurora 1.5.2-1' 'uboot-asahi 2026.07-2'
  exit 0
fi
exec $(printf '%q' "$mac_stubs/pacman") "\$@"
SH
# A boot check that must never run.
printf '#!/bin/bash\necho ran >>"$CHECK_RAN"\nexit 1\n' >"$tmp/check-stub/omarchy-apple-silicon-boot-check"
chmod +x "$fake"/* "$tmp/check-stub"/*

tree_state() {
  find "$mac_root" -path "$mac_root/run" -prune -o -print0 | sort -z | xargs -0 stat -c '%n %s %Y %a' 2>/dev/null
  find "$mac_root" -path "$mac_root/run" -prune -o -type f -print0 | sort -z | xargs -0 sha256sum
}

snapshot_cmdline='root=UUID=r rw rootflags=subvol=/@/.snapshots/7/snapshot,x-systemd.device-timeout=0 quiet splash'
live_cmdline='root=UUID=r rw rootflags=subvol=@,x-systemd.device-timeout=0 quiet splash'

# Runs the hook on the fixture Mac as limine-snapper-sync would: $1 is its
# command line (HOOK_CMDLINE), $2 the kernel command line the Mac booted.
# Extra arguments go to the check itself (a snapshot root).
run_check() {
  local hook_cmdline=$1 cmdline=$2
  shift 2
  printf '%s\n' "$cmdline" >"$tmp/cmdline"
  : >"$tmp/check-ran"
  tree_state >"$tmp/before"
  set +e
  (
    eval "$(limine_mac_env "$ROOT/bin" "${TEST_UNAME:-}")"
    export PATH="${TEST_PATH_FIRST:-$fake}:$fake:$PATH"
    export CHECK_RAN="$tmp/check-ran" HOOK_CMDLINE="$hook_cmdline" OMARCHY_CMDLINE="$tmp/cmdline"
    export OMARCHY_LIMINE_GATE="$mac_root/var/lib/omarchy/limine.enabled" OMARCHY_LIMINE_DEFAULT="$mac_root/etc/default/limine"
    export OMARCHY_BOOT_DIR="$mac_root/boot" OMARCHY_SNAPSHOTS_DIR="$tmp/snapshots"
    bash "$check" "$@" </dev/null
  ) >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
  tree_state >"$tmp/after"
  diff -q "$tmp/before" "$tmp/after" >/dev/null || fail "the check changes no boot file"
  [[ ! -s $mac_state/mounts && -z $(ls -A "$mac_root/run") ]] || fail "the check leaves nothing mounted"
}

expect_allowed() {
  (( status == 0 )) || fail "$1 is restored (status $status: $(cat "$tmp/err"))"
}

# $2 and on: text the explanation must hold.
expect_refused() {
  local description=$1 text
  shift
  (( status == 100 )) || fail "$description is refused with a status that stops limine-snapper-sync (status $status)"
  for text; do
    grep -Fq -- "$text" "$tmp/err" || fail "$description is explained: '$text' missing from: $(cat "$tmp/err")"
  done
}

# Anything but a restore passes straight through: every Limine UKI rebuild and
# snapshot sync runs the pre hooks too.
limine_mac
for hook_cmdline in "" "--add 3" "--no-force-save --add 3" "--debounce" "--no-hooks"; do
  TEST_PATH_FIRST=$tmp/check-stub run_check "$hook_cmdline" "$snapshot_cmdline"
  (( status == 0 )) && [[ ! -s $tmp/out && ! -s $tmp/err && ! -s $tmp/check-ran ]] ||
    fail "limine-snapper-sync '$hook_cmdline' passes the hook untouched"
done
TEST_APPLE=1 TEST_PATH_FIRST=$tmp/check-stub run_check "--restore --no-mutex" "$snapshot_cmdline"
(( status == 0 )) && [[ ! -s $tmp/err && ! -s $tmp/check-ran ]] || fail "a restore on anything but a Mac is not this hook's to check"
pass "the hook stays out of everything but a restore on a Mac"

# The snapshot booted from the Limine menu matches the boot files: restored.
limine_mac
run_check "--restore --no-mutex" "$snapshot_cmdline"
expect_allowed "a snapshot taken with the installed kernel and boot firmware"
grep -Fq "Snapshot 7 matches this Mac's boot files" "$tmp/out" || fail "the check says the snapshot matches"
pass "a snapshot that matches the boot files is restored"

# Only what the next boot reads, as update-verify checks it: LUKS keyslots are
# outside every snapshot and a drifted module is the snapshot's own, so neither
# stops a restore, though the full boot check refuses both.
limine_mac
limine_mac_luks 1
run_check "--restore --no-mutex" "$snapshot_cmdline"
expect_allowed "a snapshot on an encrypted Mac with a third LUKS keyslot"
limine_mac
printf '/usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\n' "$mac_kver" >"$mac_state/drift-linux-aurora"
run_check "--restore --no-mutex" "$snapshot_cmdline"
expect_allowed "a snapshot with a kernel module that drifted from its mtree"
pass "the restore checks the boot chain, not what the next boot does not read"

# The kernel Limine saved with the snapshot is what the restore boots next: it
# must be the snapshot's own.
TEST_UNAME=6.16.0-aurora9-ARCH run_check "--restore --no-mutex" "$snapshot_cmdline"
expect_refused "a snapshot booted on a kernel other than its installed one" \
  "running kernel is 6.16.0-aurora9-ARCH, not the installed linux-aurora $mac_kver"
pass "a snapshot whose saved kernel is not its installed one is refused"

# A kernel update since the snapshot: /boot, the UKI and its menu carry the new
# kernel, the snapshot the old one.
limine_mac
printf 'linux-aurora kernel 6.18.0-aurora1-ARCH\n' >"$mac_root/boot/vmlinuz-linux-aurora"
{ cat "$mac_root/boot/vmlinuz-linux-aurora"; printf 'initrd\n'; } >"$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
limine_mac_menu
run_check "--restore --no-mutex" "$snapshot_cmdline"
expect_refused "a snapshot from before a kernel update" \
  "Snapshot 7 does not match this Mac's boot files, so it is not restored" \
  "/boot/vmlinuz-linux-aurora is not the $mac_kver kernel linux-aurora installed" \
  "A snapshot holds the root file system only" \
  "taken before a kernel" \
  "first install its kernel and boot firmware packages on the" \
  "linux-aurora 6.17.0.aurora1-1" "m1n1-aurora 1.5.2-1" "uboot-asahi 2026.07-2"
pass "a snapshot from before a kernel update is refused, with why and what to do"

# An m1n1 update since the snapshot: boot.bin on the ESP holds the new m1n1.
limine_mac
printf 'm1n1 stage 2 from the next m1n1-aurora\n' >"$tmp/m1n1.bin"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
run_check "--restore" "$snapshot_cmdline"
expect_refused "a snapshot from before an m1n1 update" \
  "Snapshot 7 does not match this Mac's boot files" \
  "m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1, linux-aurora $mac_kver's device trees, U-Boot"
pass "a snapshot from before a boot firmware update is refused"

# A snapshot from before Limine was activated carries no Limine setup.
limine_mac
rm "$mac_root/var/lib/omarchy/limine.enabled"
TEST_PATH_FIRST=$tmp/check-stub run_check "--restore --no-mutex" "$snapshot_cmdline"
expect_refused "a snapshot from before the Limine activation" \
  "Snapshot 7 was taken before Limine was activated on this Mac" "boots through GRUB"
[[ ! -s $tmp/check-ran ]] || fail "a snapshot from before Limine is refused before any boot check"
pass "a snapshot from before the Limine activation is refused, and why"

# From the running system, limine-snapper-restore would let any snapshot be
# picked unchecked: a Mac restores the snapshot it booted.
limine_mac
TEST_PATH_FIRST=$tmp/check-stub run_check "--restore --no-mutex" "$live_cmdline"
expect_refused "a restore from the running system" \
  "open Snapshots" "run omarchy-snapshot restore once it" \
  "Snapshots taken before Limine was activated on this Mac are not in that menu" \
  "cannot be booted or restored"
rm "$mac_root/var/lib/omarchy/limine.enabled"
TEST_PATH_FIRST=$tmp/check-stub run_check "--restore --no-mutex" "$live_cmdline"
expect_refused "limine-snapper-restore on a Mac that boots GRUB" \
  "This Mac boots GRUB, so limine-snapper-restore does not apply" "omarchy-snapshot restore"
[[ ! -s $tmp/check-ran ]] || fail "no boot check runs outside a snapshot"
pass "outside a snapshot the restore is refused: boot the snapshot first, or use the GRUB restore"

# Kernel files alone (snapper rollback): the snapshot's kernel must be /boot's.
# $1 is the snapshot's kernel image.
snapshot_tree() {
  local tree=$1 modules
  modules=$tree/usr/lib/modules/$mac_kver
  rm -rf "$tree"
  mkdir -p "$modules"
  printf '%s\n' "$2" >"$modules/vmlinuz"
  printf 'linux-aurora\n' >"$modules/pkgbase"
  : >"$modules/modules.dep"
}
limine_mac
snapshot_tree "$tmp/snapshots/7/snapshot" "linux-aurora kernel $mac_kver"
run_check "--restore-kernels 7" "$live_cmdline"
expect_allowed "kernel files from a snapshot with the kernel on /boot"
snapshot_tree "$tmp/snapshots/7/snapshot" "linux-aurora kernel from another build"
run_check "--restore-kernels 7" "$live_cmdline"
expect_refused "kernel files from a snapshot with another kernel" \
  "Snapshot 7 has linux-aurora $mac_kver, not the linux-aurora kernel on the boot partition" \
  "A snapshot holds the root file system only"
run_check "--restore-kernels" "$live_cmdline"
expect_refused "kernel files with no snapshot named" "names no snapshot"
pass "restoring a snapshot's kernel files alone needs the kernel on /boot"

# The subvolume swap on a Mac that boots GRUB checks the snapshot root it is
# about to swap in.
limine_mac
snapshot_tree "$tmp/tree" "linux-aurora kernel $mac_kver"
run_check "" "$live_cmdline" "$tmp/tree"
(( status == 0 )) && [[ ! -s $tmp/err ]] || fail "a snapshot root with the kernel on /boot passes (status $status: $(cat "$tmp/err"))"
snapshot_tree "$tmp/tree" "linux-aurora kernel from another build"
run_check "" "$live_cmdline" "$tmp/tree"
(( status == 1 )) && grep -Fq "This snapshot has linux-aurora $mac_kver, not the linux-aurora kernel on the boot partition" "$tmp/err" &&
  grep -Fq "install its kernel package on the current system" "$tmp/err" ||
  fail "a snapshot root with another kernel build is refused and explained (status $status: $(cat "$tmp/err"))"
rm -f "$tmp/tree/usr/lib/modules/$mac_kver/modules.dep"
cp "$mac_root/boot/vmlinuz-linux-aurora" "$tmp/tree/usr/lib/modules/$mac_kver/vmlinuz"
run_check "" "$live_cmdline" "$tmp/tree"
(( status == 1 )) || fail "a snapshot root without the kernel's module dependencies is refused"
printf 'linux-asahi\n' >"$tmp/tree/usr/lib/modules/$mac_kver/pkgbase"
run_check "" "$live_cmdline" "$tmp/tree"
(( status == 1 )) && grep -Fq "This snapshot has no linux-aurora kernel" "$tmp/err" ||
  fail "a snapshot root from another kernel package is refused (status $status: $(cat "$tmp/err"))"
pass "a snapshot root is checked for the kernel on /boot"
