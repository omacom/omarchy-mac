#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/test/fixtures/limine-mac.sh"

require_command gzip
require_command b2sum

# limine-snapper-sync runs /etc/boot/hooks/pre.d before it restores a snapshot
# and post.d after it; a pre hook that exits 100 or more stops the restore, a
# post hook keeps it from offering the reboot. omarchy-mac-snapshot-check is
# both on a Mac: the snapshot booted from the Limine menu is restored only when
# it passes the boot check against the boot files outside it, and whatever the
# restore put back must hold that snapshot's boot files.
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
[[ $(readlink "$tmp/stage/etc/boot/hooks/post.d/99-omarchy-mac-snapshot-check") == /usr/bin/omarchy-mac-snapshot-check ]] ||
  fail "the package links the check into limine-snapper-sync's post hooks, after the others"
pass "the package installs the restore check as a limine-snapper-sync pre and post hook"

limine_mac_init "$tmp/mac"
fake=$tmp/bin
mkdir -p "$fake" "$tmp/check-stub"
# TEST_PLATFORM: the platform the detector reports, or "error" when it cannot
# tell. TEST_NO_DETECTOR leaves it out, as on a root from before it.
mkdir -p "$tmp/detector" "$tmp/no-detector"
cat >"$tmp/detector/omarchy-hw-platform" <<'SH'
#!/bin/bash
[[ ${TEST_PLATFORM:-apple-silicon} != error ]] || exit 1
echo "${TEST_PLATFORM:-apple-silicon}"
SH
# TEST_APPLE_STATUS: an exit status other than a clear answer, such as 127.
cat >"$fake/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
[[ -z ${TEST_APPLE_STATUS:-} ]] || exit "$TEST_APPLE_STATUS"
[[ ${TEST_PLATFORM:-apple-silicon} == apple-silicon ]]
SH
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
chmod +x "$fake"/* "$tmp/check-stub"/* "$tmp/detector"/*

tree_state() {
  find "$mac_root" -path "$mac_root/run" -prune -o -print0 | sort -z | xargs -0 stat -c '%n %s %Y %a' 2>/dev/null
  find "$mac_root" -path "$mac_root/run" -prune -o -type f -print0 | sort -z | xargs -0 sha256sum
}

snapshot_cmdline='root=UUID=r rw rootflags=subvol=/@/.snapshots/7/snapshot,x-systemd.device-timeout=0 quiet splash'
live_cmdline='root=UUID=r rw rootflags=subvol=@,x-systemd.device-timeout=0 quiet splash'

# The pre and post hooks as limine-snapper-sync finds them.
mkdir -p "$tmp/hooks/pre.d" "$tmp/hooks/post.d"
ln -s "$check" "$tmp/hooks/pre.d/04-omarchy-mac-snapshot-check"
ln -s "$check" "$tmp/hooks/post.d/99-omarchy-mac-snapshot-check"
post_hook=$tmp/hooks/post.d/99-omarchy-mac-snapshot-check

# Runs the hook on the fixture Mac as limine-snapper-sync would: $1 is its
# command line (HOOK_CMDLINE), $2 the kernel command line the Mac booted.
# Extra arguments go to the check itself (a snapshot root). TEST_HOOK runs
# another link to it; $tmp/top is the btrfs top level, $tmp/restore.lock
# limine-snapper-sync's restore lock.
run_check() {
  local hook_cmdline=$1 cmdline=$2
  shift 2
  printf '%s\n' "$cmdline" >"$tmp/cmdline"
  : >"$tmp/check-ran"
  tree_state >"$tmp/before"
  set +e
  (
    eval "$(limine_mac_env "$ROOT/bin" "${TEST_UNAME:-}")"
    local detector=$tmp/detector
    [[ -z ${TEST_NO_DETECTOR:-} ]] || detector=$tmp/no-detector
    export PATH="${TEST_PATH_FIRST:-$fake}:$fake:$detector:$PATH"
    export CHECK_RAN="$tmp/check-ran" HOOK_CMDLINE="$hook_cmdline" OMARCHY_CMDLINE="$tmp/cmdline"
    export OMARCHY_LIMINE_GATE="$mac_root/var/lib/omarchy/limine.enabled" OMARCHY_LIMINE_DEFAULT="$mac_root/etc/default/limine"
    export OMARCHY_BOOT_DIR="$mac_root/boot" OMARCHY_SNAPSHOTS_DIR="$tmp/snapshots"
    export OMARCHY_SNAPSHOT_TOP="$tmp/top" OMARCHY_SNAPSHOT_RESTORE_LOCK="$tmp/restore.lock" OMARCHY_SNAPSHOT_CHECK_STATE="$tmp/state"
    export OMARCHY_SNAPSHOT_TOP_DIR="$tmp/top-dir"
    [[ -z ${TEST_NO_TOP:-} ]] || unset OMARCHY_SNAPSHOT_TOP
    bash "${TEST_HOOK:-$tmp/hooks/pre.d/04-omarchy-mac-snapshot-check}" "$@" </dev/null
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
TEST_PLATFORM=generic TEST_PATH_FIRST=$tmp/check-stub run_check "--restore --no-mutex" "$snapshot_cmdline"
(( status == 0 )) && [[ ! -s $tmp/err && ! -s $tmp/check-ran ]] || fail "a restore on anything but a Mac is not this hook's to check"
pass "the hook stays out of everything but a restore on a Mac"

TEST_PLATFORM=error TEST_PATH_FIRST=$tmp/check-stub run_check "--restore --no-mutex" "$snapshot_cmdline"
expect_refused "a restore where the platform cannot be told" "Cannot tell which platform this is"
[[ ! -s $tmp/check-ran ]] || fail "no boot check runs when the platform cannot be told"
pass "a restore is refused when the platform cannot be told"

TEST_NO_DETECTOR=1 TEST_PATH_FIRST=$tmp/check-stub run_check "--restore --no-mutex" "$live_cmdline"
expect_refused "a restore from the running system of a root without the platform detector" "open Snapshots"
TEST_NO_DETECTOR=1 TEST_PLATFORM=generic TEST_PATH_FIRST=$tmp/check-stub run_check "--restore --no-mutex" "$snapshot_cmdline"
(( status == 0 )) && [[ ! -s $tmp/err && ! -s $tmp/check-ran ]] || fail "a root without the detector and not a Mac is not this hook's to check"
TEST_NO_DETECTOR=1 TEST_APPLE_STATUS=127 TEST_PATH_FIRST=$tmp/check-stub run_check "--restore --no-mutex" "$snapshot_cmdline"
expect_refused "a restore where omarchy-hw-apple-silicon is missing" "Cannot tell which platform this is"
pass "a root from before the platform detector asks omarchy-hw-apple-silicon, and only a clear answer counts"

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
  "first install its kernel, boot firmware and Limine" \
  "linux-aurora 6.17.0.aurora1-1" "m1n1-aurora 1.5.2-1" "uboot-asahi 2026.07-2" "limine 12.9.0-1"
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

# A Limine update since the snapshot: the ESP holds the new loader.
limine_mac
printf 'LIMINE next\n' >"$mac_esp/EFI/BOOT/BOOTAA64.EFI"
run_check "--restore" "$snapshot_cmdline"
expect_refused "a snapshot from before a Limine update" \
  "Snapshot 7 does not match this Mac's boot files" "BOOTAA64.EFI" "limine 12.9.0-1"
pass "a snapshot from before a Limine update is refused, and its Limine package is named"

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
  "Snapshots taken before Limine was activated on this Mac cannot be restored" \
  "that is gets refused"
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
# From a snapshot boot /.snapshots is empty: the snapshot is read off the top level.
rm -rf "$tmp/snapshots"
snapshot_tree "$tmp/top/@/.snapshots/7/snapshot" "linux-aurora kernel $mac_kver"
run_check "--restore-kernels 7" "$snapshot_cmdline"
expect_allowed "kernel files from a snapshot read off the top level"
rm -rf "$tmp/top"
run_check "--restore-kernels 7" "$snapshot_cmdline"
expect_refused "kernel files from a snapshot that cannot be read" "Cannot read snapshot 7"
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

# After the restore: @ is whatever limine-snapper-sync put back, the booted
# snapshot or one picked from its own list. $1 is its kernel image; the rest of
# its boot files are the running root's. Snapshot 12 is the backup of the
# previous root the restore wrote after the pre hook let it through; 20 is
# older, from before it.
restored_root() {
  local restored=$tmp/top/@ number
  rm -rf "$tmp/top" "$tmp/state"
  mkdir -p "$tmp/state"
  for number in 7 12 20; do
    mkdir -p "$restored/.snapshots/$number"
    printf '<snapshot><num>%s</num></snapshot>\n' "$number" >"$restored/.snapshots/$number/info.xml"
  done
  touch -d '-2 minutes' "$restored/.snapshots/7/info.xml" "$restored/.snapshots/20/info.xml"
  touch -d '-1 minute' "$tmp/state/started"
  cp -a "$mac_root/usr" "$mac_root/etc" "$mac_root/var" "$restored/"
  printf '%s\n' "$1" >"$restored/usr/lib/modules/$mac_kver/vmlinuz"
  printf 'linux-aurora\n' >"$restored/usr/lib/modules/$mac_kver/pkgbase"
  : >"$restored/usr/lib/modules/$mac_kver/modules.dep"
  echo restored >"$tmp/restore.lock"
}
run_post() {
  TEST_HOOK=$post_hook run_check "$@"
}
expect_undo() {
  local description=$1
  shift
  expect_refused "$description" "The restore put back a root this Mac's boot files do not match" \
    "Do not reboot yet" "pick snapshot 12, the backup this restore just made" \
    'Ignore the "Please reboot manually"' "$@"
  [[ $(cat "$tmp/state/undo") == 12 ]] || fail "$description leaves the backup to undo to"
}

limine_mac
restored_root "linux-aurora kernel $mac_kver"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_allowed "a restored root with the running root's boot files"
grep -Fq "The restored root matches this Mac's boot files" "$tmp/out" || fail "the post hook says the restored root matches"
for hook_cmdline in "" "--add 3" "--restore-kernels 7"; do
  rm -rf "$tmp/top/@/usr/lib/modules"
  run_post "$hook_cmdline" "$snapshot_cmdline"
  (( status == 0 )) && [[ ! -s $tmp/out && ! -s $tmp/err ]] || fail "limine-snapper-sync '$hook_cmdline' passes the post hook untouched"
done
restored_root "linux-aurora kernel from another build"
printf 'cancelled\n' >"$tmp/restore.lock"
run_post "--restore --no-mutex" "$snapshot_cmdline"
(( status == 0 )) && [[ ! -s $tmp/err ]] || fail "a restore that did not finish leaves the post hook nothing to check"
pass "the post hook passes a restored root with the booted snapshot's boot files, and stays out of the rest"

limine_mac
restored_root "linux-aurora kernel from another build"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a snapshot picked from the list with another kernel" \
  "The restored root has linux-aurora $mac_kver, not the linux-aurora kernel on the boot partition"
restored_root "linux-aurora kernel $mac_kver"
printf 'm1n1 stage 2 from an earlier m1n1-aurora\n' >"$tmp/top/@/usr/lib/asahi-boot/m1n1.bin"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a snapshot picked from the list with another m1n1" "m1n1 or U-Boot is not the one on the ESP"
restored_root "linux-aurora kernel $mac_kver"
limine_mac_dtb "$tmp/top/@${mac_dtbs[0]}" "from an earlier build"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a snapshot picked from the list with other device trees" "device trees are not the ones in m1n1 on the ESP"
restored_root "linux-aurora kernel $mac_kver"
printf 'LIMINE earlier\n' >"$tmp/top/@/usr/share/limine/BOOTAA64.EFI"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a snapshot picked from the list with another Limine" "Limine is not the one on the ESP"
restored_root "linux-aurora kernel $mac_kver"
printf 'root UUID=luks none luks\n' >"$mac_root/etc/crypttab"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a snapshot picked from the list from before encryption" "/etc/crypttab is not the one the Limine command line unlocks"
rm "$mac_root/etc/crypttab"
restored_root "linux-aurora kernel $mac_kver"
printf 'UUID=r / btrfs rw,subvol=/@old 0 0\n' >"$tmp/top/@/etc/fstab"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a snapshot picked from the list that mounts another root" "mounts / differently"
pass "the post hook refuses a restored root with other boot files, and says how to undo it"

# A snapshot boot's overlay comments out the running root's fstab row; the
# restored root's own row is the same mount.
limine_mac
restored_root "linux-aurora kernel $mac_kver"
sed -i 's|^UUID=r|# omarchy-mac-snapshot-overlay: UUID=r|' "$mac_root/etc/fstab"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_allowed "a restored root whose fstab row the snapshot boot commented out"
pass "the post hook reads the running root's fstab row through the snapshot overlay"

# Undoing a refused restore: the ESP now holds the refused root's UKI, so the
# pre hook lets the next restore through and the post hook checks its result.
limine_mac
restored_root "linux-aurora kernel from another build"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a snapshot picked from the list with another kernel"
{ printf 'linux-aurora kernel from another build\n'; printf 'initrd\n'; } >"$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
run_check "--restore --no-mutex" "$snapshot_cmdline"
(( status == 0 )) && grep -Fq "Press l and pick snapshot 12, the backup that restore made." "$tmp/out" ||
  fail "the restore that undoes a refused one is let through (status $status: $(cat "$tmp/out" "$tmp/err"))"
# A backup that is gone is not named.
printf '99\n' >"$tmp/state/undo"
run_check "--restore --no-mutex" "$snapshot_cmdline"
(( status == 0 )) && grep -Fq "Press l and pick the backup that restore made." "$tmp/out" ||
  fail "a backup that no longer exists is not named (status $status: $(cat "$tmp/out" "$tmp/err"))"
limine_mac
cp "$tmp/state/undo" "$tmp/undo"
restored_root "linux-aurora kernel $mac_kver"
cp "$tmp/undo" "$tmp/state/undo"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_allowed "the previous root put back"
[[ ! -e $tmp/state/undo ]] || fail "a restored root that matches ends the undo"
pass "a refused restore can be undone through the hooks"

# An undo left over does not skip the check of a booted root that matches.
limine_mac
restored_root "linux-aurora kernel $mac_kver"
printf '12\n' >"$tmp/state/undo"
run_check "--restore --no-mutex" "$snapshot_cmdline"
expect_allowed "a matching snapshot with an undo left over"
grep -Fq "Snapshot 7 matches this Mac's boot files" "$tmp/out" && ! grep -Fq "let through" "$tmp/out" ||
  fail "a leftover undo lets nothing skip the check" "$(cat "$tmp/out")"
pass "a leftover undo only applies while the booted root fails its check"

# A root from before the Limine activation, picked from the list, is refused
# after the restore as the pre hook refuses it booted.
limine_mac
restored_root "linux-aurora kernel $mac_kver"
rm "$tmp/top/@/var/lib/omarchy/limine.enabled"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a snapshot from before the Limine activation picked from the list" "is from before Limine was activated on this Mac"
restored_root "linux-aurora kernel $mac_kver"
printf 'ESP_PATH="/boot"\nENABLE_UKI=yes\n' >"$tmp/top/@/etc/default/limine"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a snapshot whose Limine writes to another ESP" "writes to another ESP"
pass "the post hook refuses a restored root from before the Limine activation"

# The post hook reads the restored root off the top level it mounts read-only,
# and unmounts it again.
mkdir -p "$tmp/mount-stub"
cat >"$tmp/mount-stub/mount" <<'SH'
#!/bin/bash
[[ $* == "-o ro,subvolid=5 /dev/disk/by-uuid/r "* ]] || exit 32
cp -a "$TEST_TOP_SOURCE/." "$4/"
echo "$4" >>"$MAC_STATE/mounts"
SH
chmod +x "$tmp/mount-stub/mount"
limine_mac
restored_root "linux-aurora kernel $mac_kver"
mkdir -p "$tmp/top-dir"
TEST_TOP_SOURCE=$tmp/top TEST_PATH_FIRST=$tmp/mount-stub TEST_NO_TOP=1 run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_allowed "a restored root read off the mounted top level"
[[ -z $(ls -A "$tmp/top-dir") ]] || fail "the top level is unmounted and its mountpoint removed"
pass "the post hook mounts the top level read-only and leaves nothing behind"

# When it cannot read the restored root, or tell the platform, nothing was
# checked: it says so, and arms no undo that would let the next restore skip
# its check.
expect_unchecked() {
  local description=$1
  shift
  expect_refused "$description" "The restored root was not checked against this Mac's boot files" "$@"
  [[ ! -e $tmp/state/undo ]] || fail "$description arms no undo"
  ! grep -Fq "Ignore the" "$tmp/err" || fail "$description does not say to ignore the reboot prompt"
}
limine_mac
restored_root "linux-aurora kernel $mac_kver"
TEST_NO_TOP=1 run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_unchecked "a restored root on a top level that cannot be mounted" "Cannot read the btrfs top level"
[[ -z $(ls -A "$tmp/top-dir") ]] || fail "a failed mount leaves no mountpoint behind"
TEST_NO_DETECTOR=1 TEST_APPLE_STATUS=127 run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_unchecked "a restore where the platform cannot be told" "Cannot tell which platform this is"
rm -rf "$tmp/top/@"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_unchecked "a restore that left no @" "left no root subvolume @"
pass "the post hook reports what it cannot check, and arms no undo"

# The UKI the restore put back must carry the restored kernel.
limine_mac
restored_root "linux-aurora kernel $mac_kver"
{ printf 'linux-aurora kernel 6.16.0-aurora9-ARCH\n'; printf 'initrd\n'; } >"$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
run_post "--restore --no-mutex" "$snapshot_cmdline"
expect_undo "a restore that put back a UKI with another kernel" "does not carry the restored root's $mac_kver kernel"
pass "the post hook checks the UKI the restore put back"
