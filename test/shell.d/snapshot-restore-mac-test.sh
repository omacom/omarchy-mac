#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"
source "$ROOT/packages/omarchy-mac/boot/test/fixtures/limine-mac.sh"

require_platform_fixtures "omarchy-snapshot restore on platform fixtures"
require_command gzip
require_command b2sum

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for platform in apple-silicon generic; do
  fake_platform "$tmp/$platform" "$platform"
done
limine_mac_init "$tmp/mac"

# sudo, snapper and the GRUB-era restore record themselves; the omarchy-mac-boot
# commands are the package's own, with omarchy-mac-limine-active recorded.
common=$tmp/common
mkdir -p "$common" "$tmp/limine" "$tmp/hooks" "$tmp/no-hooks"
cat >"$common/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >>"$CALLS"
exec "$@"
SH
printf '#!/bin/bash\nexit 0\n' >"$common/snapper"
printf '#!/bin/bash\nexit 0\n' >"$common/limine-update"
printf '#!/bin/bash\necho "omarchy-system-snapshot-restore $*" >>"$CALLS"\n' >"$common/omarchy-system-snapshot-restore"
cat >"$common/omarchy-mac-limine-active" <<SH
#!/bin/bash
echo omarchy-mac-limine-active >>"\$CALLS"
exec bash $(printf '%q' "$ROOT/packages/omarchy-mac/boot/bin/omarchy-mac-limine-active")
SH
# limine-snapper-restore as root runs limine-snapper-sync --restore, which runs
# every pre hook first and stops the restore at one that exits 100 or more.
cat >"$tmp/limine/limine-snapper-restore" <<'SH'
#!/bin/bash
export HOOK_CALLER=limine-snapper-restore HOOK_CMDLINE="--restore --no-mutex"
for hook in "$HOOKS_DIR"/*; do
  [[ -f $hook && -x $hook ]] || continue
  rc=0
  "$hook" || rc=$?
  (( rc == 0 )) && continue
  if (( rc >= 100 )); then
    echo "ERROR: pre hook failed (fatal, exit code $rc): $hook" >&2
    echo "Aborting limine-snapper-restore: pre hook failed"
    exit 2
  fi
  echo "WARNING: pre hook failed (exit code $rc): $hook" >&2
done
echo restored >>"$CALLS"
SH
chmod +x "$common"/* "$tmp/limine"/*
ln -s "$ROOT/packages/omarchy-mac/boot/bin/omarchy-mac-snapshot-check" "$tmp/hooks/04-omarchy-mac-snapshot-check"

snapshot_cmdline='root=UUID=r rw rootflags=subvol=/@/.snapshots/7/snapshot quiet'

# omarchy-snapshot restore on platform $1; $2 is "limine" when limine-snapper-sync
# is installed, and $3 the directory of pre hooks it runs.
run_restore() {
  local platform=$1 limine=$2 hooks=${3:-$tmp/no-hooks} path
  path=$tmp/$platform/bin:$common
  [[ $limine != limine ]] || path+=:$tmp/limine
  path+=:$ROOT/bin:$ROOT/packages/omarchy-mac/boot/bin
  printf '%s\n' "$snapshot_cmdline" >"$tmp/cmdline"
  : >"$tmp/calls"
  set +e
  (
    eval "$(limine_mac_env "$path")"
    export PATH="$path:$PATH"
    export CALLS="$tmp/calls" HOOKS_DIR="$hooks" OMARCHY_PROC_ROOT="$tmp/$platform/proc" OMARCHY_CMDLINE="$tmp/cmdline"
    export OMARCHY_LIMINE_GATE="$mac_root/var/lib/omarchy/limine.enabled" OMARCHY_LIMINE_DEFAULT="$mac_root/etc/default/limine"
    export OMARCHY_BOOT_DIR="$mac_root/boot"
    bash "$ROOT/bin/omarchy-snapshot" restore </dev/null
  ) >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
}

# x86: exactly as before, and nothing asks whether a Mac boots Limine.
limine_mac
run_restore generic limine
(( status == 0 )) && [[ $(cat "$tmp/calls") == $'sudo limine-snapper-restore\nrestored' ]] ||
  fail "x86 with Limine restores with limine-snapper-restore" "$(cat "$tmp/calls" "$tmp/err")"
run_restore generic none
(( status == 0 )) && [[ $(cat "$tmp/calls") == $'sudo omarchy-system-snapshot-restore\nomarchy-system-snapshot-restore ' ]] ||
  fail "x86 without limine-snapper-sync swaps the root subvolume" "$(cat "$tmp/calls" "$tmp/err")"
pass "x86 restores as before, without any Mac check"

# A Mac that boots GRUB has limine-snapper-sync installed but not in use.
limine_mac
rm "$mac_root/var/lib/omarchy/limine.enabled"
run_restore apple-silicon limine "$tmp/hooks"
(( status == 0 )) && grep -Fxq 'sudo omarchy-system-snapshot-restore' "$tmp/calls" && ! grep -q 'limine-snapper-restore\|restored' "$tmp/calls" ||
  fail "a GRUB Mac restores with the subvolume swap, never limine-snapper-restore" "$(cat "$tmp/calls" "$tmp/err")"
pass "a Mac that boots GRUB uses the GRUB-era restore"

# A Limine Mac booted into snapshot 7 from the menu: the x86 restore, which the
# package's pre hook lets through when the snapshot matches the boot files.
limine_mac
run_restore apple-silicon limine "$tmp/hooks"
(( status == 0 )) && grep -Fxq 'sudo limine-snapper-restore' "$tmp/calls" && grep -Fxq restored "$tmp/calls" ||
  fail "a Limine Mac restores a matching snapshot with limine-snapper-restore" "$(cat "$tmp/calls" "$tmp/out" "$tmp/err")"
! grep -q 'omarchy-system-snapshot-restore' "$tmp/calls" || fail "a Limine Mac never runs the GRUB-era restore"
grep -Fq "Snapshot 7 matches this Mac's boot files" "$tmp/out" || fail "the restore says the snapshot was checked" "$(cat "$tmp/out")"
pass "a Limine Mac restores a snapshot that matches its boot files through limine-snapper-restore"

# The same, after a kernel update the snapshot predates.
limine_mac
printf 'linux-aurora kernel 6.18.0-aurora1-ARCH\n' >"$mac_root/boot/vmlinuz-linux-aurora"
run_restore apple-silicon limine "$tmp/hooks"
(( status != 0 )) && ! grep -Fxq restored "$tmp/calls" ||
  fail "a snapshot from before a kernel update is not restored" "$(cat "$tmp/calls" "$tmp/err")"
grep -Fq "Snapshot 7 does not match this Mac's boot files, so it is not restored" "$tmp/err" &&
  grep -Fq "/boot/vmlinuz-linux-aurora is not the $mac_kver kernel linux-aurora installed" "$tmp/err" &&
  grep -Fq "A snapshot holds the root file system only" "$tmp/err" ||
  fail "the refusal says what differs and why" "$(cat "$tmp/err")"
pass "a Limine Mac refuses a snapshot from before a kernel update, and explains"

# The GRUB-era restore itself: refused on a Limine Mac before anything else,
# while a GRUB Mac and x86 reach its usual checks.
run_swap_restore() {
  local platform=$1
  set +e
  (
    export PATH="$tmp/$platform/bin:$common:$ROOT/bin:$ROOT/packages/omarchy-mac/boot/bin:$PATH"
    export CALLS="$tmp/calls" OMARCHY_PROC_ROOT="$tmp/$platform/proc"
    export OMARCHY_LIMINE_GATE="$mac_root/var/lib/omarchy/limine.enabled" OMARCHY_LIMINE_DEFAULT="$mac_root/etc/default/limine"
    bash "$ROOT/bin/omarchy-system-snapshot-restore" </dev/null
  ) >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
}
limine_mac
run_swap_restore apple-silicon
(( status != 0 )) && grep -Fq "this Mac boots Limine" "$tmp/err" && grep -Fq "Snapshots in the Limine menu" "$tmp/err" ||
  fail "the subvolume swap refuses a Limine Mac" "$(cat "$tmp/err")"
rm "$mac_root/var/lib/omarchy/limine.enabled"
run_swap_restore apple-silicon
grep -Fq "run as root" "$tmp/err" || fail "a GRUB Mac reaches the subvolume swap" "$(cat "$tmp/err")"
run_swap_restore generic
grep -Fq "run as root" "$tmp/err" && ! grep -Fq Limine "$tmp/err" || fail "x86 reaches the subvolume swap as before" "$(cat "$tmp/err")"
pass "the GRUB-era restore runs only where Limine does not boot the Mac"

# On a GRUB Mac the swap restores only a snapshot root carrying the kernel on
# /boot: GRUB boots that kernel with the restored root's modules.
snapshot_root() {
  local modules=$tmp/tree/usr/lib/modules/$mac_kver
  rm -rf "$tmp/tree"
  mkdir -p "$modules"
  printf '%s\n' "$1" >"$modules/vmlinuz"
  printf 'linux-aurora\n' >"$modules/pkgbase"
  : >"$modules/modules.dep"
}
swap_check() {
  local path=$1
  set +e
  (
    eval "$(limine_mac_env "$path")"
    export PATH="$path:$PATH" OMARCHY_PROC_ROOT="$tmp/apple-silicon/proc" OMARCHY_BOOT_DIR="$mac_root/boot"
    bash -c 'source "$1"; apple_snapshot_matches_boot "$2"' _ "$ROOT/bin/omarchy-system-snapshot-restore" "$tmp/tree"
  ) >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
}
limine_mac
with_boot=$tmp/apple-silicon/bin:$common:$ROOT/bin:$ROOT/packages/omarchy-mac/boot/bin
snapshot_root "linux-aurora kernel $mac_kver"
swap_check "$with_boot"
(( status == 0 )) || fail "a snapshot with the kernel on /boot is swapped in" "$(cat "$tmp/err")"
snapshot_root "linux-aurora kernel 6.16.0-aurora0-ARCH"
swap_check "$with_boot"
(( status != 0 )) && grep -Fq "not the linux-aurora kernel on the boot partition" "$tmp/err" ||
  fail "a snapshot with another kernel is refused and explained" "$(cat "$tmp/err")"
swap_check "$tmp/apple-silicon/bin:$common:$ROOT/bin"
(( status != 0 )) && grep -Fq "omarchy-mac-boot is not installed" "$tmp/err" ||
  fail "without omarchy-mac-boot the snapshot cannot be checked, so it is refused" "$(cat "$tmp/err")"
grep -Fq 'if (( apple )) && ! apple_snapshot_matches_boot "$TOP/$source_path"; then' "$ROOT/bin/omarchy-system-snapshot-restore" ||
  fail "the swap checks the chosen snapshot on a Mac"
pass "a GRUB Mac swaps in only a snapshot carrying the kernel on /boot"
