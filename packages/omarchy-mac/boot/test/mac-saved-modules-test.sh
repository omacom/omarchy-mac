#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/test/fixtures/limine-mac.sh"

require_command gzip
require_command b2sum

# After a kernel downgrade, kernel-modules-hook leaves the running kernel's
# modules in /usr/lib/modules until the next boot, where update-m1n1's -ARCH
# default takes their device trees. 11-omarchy-mac-saved-modules.hook retires
# that copy in the same transaction, before m1n1 is rebuilt.
hook=$ROOT/files/usr/share/libalpm/hooks/11-omarchy-mac-saved-modules.hook
retire=$ROOT/files/usr/share/libalpm/scripts/omarchy-mac-retire-saved-modules
entrypoint=$ROOT/entrypoints/update-verify
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

grep -Fxq 'Target = usr/lib/modules/*/vmlinuz' "$hook" && grep -Fxq 'When = PostTransaction' "$hook" &&
  grep -Fxq 'NeedsTargets' "$hook" && grep -Fxq "Exec = /${retire#"$ROOT/files/"}" "$hook" && [[ -x $retire ]] ||
  fail "the hook runs the packaged script after every kernel install or upgrade, with the kernels it installed"
# pacman runs the hooks of one stage in the order of their file names.
order=(10-linux-modules-post.hook "${hook##*/}" 60-depmod.hook 90-mkinitcpio-apple-install.hook 90-mkinitcpio-install.hook 95-m1n1-install.hook)
[[ $(printf '%s\n' "${order[@]}" | LC_ALL=C sort) == "$(printf '%s\n' "${order[@]}")" ]] ||
  fail "the hook runs after kernel-modules-hook restores the saved modules and before depmod, mkinitcpio, Limine and m1n1"
pass "the hook runs right after kernel-modules-hook's restore, before anything reads /usr/lib/modules"

running=6.18.0-aurora2-ARCH
stubs=$tmp/stubs
state=$tmp/state
mkdir -p "$stubs"
cat >"$stubs/uname" <<'SH'
#!/bin/bash
[[ $* == -r ]] || exec /usr/bin/uname "$@"
echo "$TEST_RUNNING"
SH
# pacman on the fixture's root: installed names the packages, owned holds
# "directory package" for the directories packages own.
cat >"$stubs/pacman" <<'SH'
#!/bin/bash
[[ $1 == --root && $2 == "$TEST_ROOT" && $3 == --dbpath && $4 == "$TEST_ROOT/var/lib/pacman/" ]] || { echo "pacman: not the fixture root: $*" >&2; exit 2; }
shift 4
case $1 in
  -Qq) grep -Fxq -- "$2" "$TEST_STATE/installed" ;;
  -Qqo)
    owner=$(awk -v path="${2#"$TEST_ROOT"}" '$1 == path { print $2; exit }' "$TEST_STATE/owned")
    if [[ -n $owner ]]; then
      echo "$owner"
    else
      echo "error: No package owns $2" >&2
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
SH
cat >"$stubs/rsync" <<'SH'
#!/bin/bash
printf 'rsync %s\n' "$*" >>"$TEST_STATE/calls"
[[ ${TEST_RSYNC_FAILS:-0} != 1 && $1 == -AHXal && $# == 3 ]] || exit 1
mkdir -p "$3"
cp -a "$2" "$3"
SH
chmod +x "$stubs"/*

limine_mac_init "$tmp/mac"
modules=$mac_root/usr/lib/modules

# The Mac just downgraded to linux-aurora $mac_kver while $running runs: the
# transaction's hooks left the running kernel's modules, device trees and all,
# where kernel-modules-hook put them back.
downgraded() {
  local dtb
  limine_mac
  mkdir -p "$modules/$running/kernel" "$modules/$running/dtbs" "$state"
  printf 'linux-aurora kernel %s\n' "$running" >"$modules/$running/vmlinuz"
  printf 'module\n' >"$modules/$running/kernel/apple-dcp.ko.zst"
  for dtb in "${mac_dtbs[@]}"; do
    limine_mac_dtb "$modules/$running/dtbs/${dtb##*/}" "from $running"
  done
  printf '%s\n' linux-aurora m1n1-aurora uboot-asahi limine kernel-modules-hook >"$state/installed"
  printf '/usr/lib/modules/%s linux-aurora\n' "$mac_kver" >"$state/owned"
  : >"$state/calls"
}

# The transaction's own hook for the kernels it installed, as pacman runs it.
retire_hook() {
  set +e
  printf 'usr/lib/modules/%s/vmlinuz\n' "${1:-$mac_kver}" |
    env TEST_RUNNING="$running" TEST_ROOT="$mac_root" TEST_STATE="$state" OMARCHY_SAVED_MODULES_ROOT="$mac_root" \
      PATH="$stubs:$PATH" bash "$retire" >"$tmp/retire.out" 2>"$tmp/retire.err"
  retire_status=$?
  set -e
}

# 95-m1n1-install.hook: update-m1n1 with ALARM's default, the device trees of
# the newest -ARCH module tree.
m1n1_hook() {
  local newest dtbs=() dtb
  newest=$(printf '%s\n' "$modules"/*-ARCH | sort -rV | head -n 1)
  for dtb in "$newest"/dtbs/*.dtb; do
    dtbs+=("${dtb#"$mac_root"}")
  done
  limine_mac_boot_bin "$mac_root/usr/lib/asahi-boot/m1n1.bin" "${dtbs[@]}"
}

verify() {
  set +e
  (
    eval "$(limine_mac_env "$ROOT/bin" "$running")"
    bash "$entrypoint"
  ) >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
}

left_with_reason() {
  (( retire_status == 0 )) && [[ ! -s $state/calls && -d $modules/$running && ! -e $modules/.old ]] &&
    grep -Fq "Leaving /usr/lib/modules/$running in place, so update-m1n1 takes the running kernel's device trees until the reboot: $2" "$tmp/retire.out" ||
    fail "$1 is left in place, and the hook says why" "status $retire_status: $(cat "$tmp/retire.out" "$tmp/retire.err" "$state/calls")"
}

left_alone() {
  (( retire_status == 0 )) && [[ ! -s $tmp/retire.out && ! -s $state/calls && -d $modules/$running && ! -e $modules/.old ]] ||
    fail "$1 is left alone" "status $retire_status: $(cat "$tmp/retire.out" "$tmp/retire.err" "$state/calls")"
}

downgraded
m1n1_hook
verify
(( status == 1 )) && grep -Fq "device tree /lib/modules/$running/dtbs/t6000-j314s.dtb is not one of linux-aurora $mac_kver's" "$tmp/err" ||
  fail "without the hook, m1n1 takes the running kernel's device trees and update-verify refuses the reboot" "status $status: $(cat "$tmp/err")"
pass "a downgrade's saved modules give m1n1 the wrong device trees, which update-verify refuses"

downgraded
retire_hook
m1n1_hook
(( retire_status == 0 )) || fail "the hook retires the saved modules" "status $retire_status: $(cat "$tmp/retire.err")"
[[ ! -e $modules/$running && -d $modules/$mac_kver ]] || fail "the running kernel's saved modules leave /usr/lib/modules" "$(ls -A "$modules")"
cmp -s "$modules/.old/$running/kernel/apple-dcp.ko.zst" <(printf 'module\n') && [[ -f $modules/.old/$running/dtbs/t6000-j314s.dtb ]] ||
  fail "they are kept in /usr/lib/modules/.old, as linux-modules-cleanup keeps them" "$(find "$modules/.old")"
grep -Fxq "rsync -AHXal $modules/$running $modules/.old/" "$state/calls" ||
  fail "they are copied the way linux-modules-cleanup copies them" "$(cat "$state/calls")"
grep -Fq "Moving the running kernel's saved modules ($running) to /usr/lib/modules/.old" "$tmp/retire.out" &&
  grep -Fq "Reboot soon" "$tmp/retire.out" || fail "the move and its cost are explained" "$(cat "$tmp/retire.out")"
verify
(( status == 0 )) && grep -Fq "installed linux-aurora $mac_kver boot files match; running $running, reboot pending" "$tmp/out" ||
  fail "update-verify passes the downgrade, with its reboot pending" "status $status: $(cat "$tmp/err")"
retire_hook
(( retire_status == 0 )) && [[ ! -s $tmp/retire.out ]] || fail "a later kernel transaction before the reboot finds nothing to do" "$(cat "$tmp/retire.out")"
pass "the hook moves a downgrade's saved modules to .old before m1n1 is rebuilt, leaving no stale module tree, and update-verify passes"

downgraded
retire_hook "$running"
left_alone "a reinstall of the running kernel itself"
printf '/usr/lib/modules/%s linux-aurora-headers\n' "$running" >>"$state/owned"
retire_hook
left_with_reason "a downgrade whose running tree the headers still own" "linux-aurora-headers still owns it; downgrade or remove linux-aurora-headers as well"
downgraded
mv "$modules/$running" "$modules/6.16.0-aurora1-ARCH"
running=6.16.0-aurora1-ARCH retire_hook
(( retire_status == 0 )) && [[ ! -s $tmp/retire.out && -d $modules/6.16.0-aurora1-ARCH && ! -e $modules/.old ]] ||
  fail "an upgrade, whose saved modules sort below the installed kernel, is left alone" "$(cat "$tmp/retire.out" "$tmp/retire.err")"
downgraded
mkdir -p "$modules/6.17.5-aurora1-ARCH"
retire_hook
left_with_reason "another module tree between the running and installed kernels" "/usr/lib/modules/6.17.5-aurora1-ARCH sits between it and the kernel this transaction installed"
downgraded
sed -i '/^kernel-modules-hook$/d' "$state/installed"
retire_hook
left_alone "a Mac without kernel-modules-hook"
downgraded
printf 'DTBS="/lib/modules/%s/dtbs/*.dtb"\n' "$mac_kver" >>"$mac_root/etc/default/update-m1n1"
retire_hook
left_alone "DTBS set in /etc/default/update-m1n1"
downgraded
printf 'M1N1_UPDATE_DISABLED=1\n' >>"$mac_root/etc/default/update-m1n1"
retire_hook
left_alone "m1n1 left to its owner"
downgraded
sed -i '/DTBS:=/d' "$mac_root/usr/bin/update-m1n1"
retire_hook
left_alone "an update-m1n1 without the -ARCH default"
downgraded
mv "$modules/$running" "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$modules/$running"
retire_hook
(( retire_status == 0 )) && [[ -L $modules/$running && ! -e $modules/.old && -d $tmp/elsewhere ]] || fail "a symlinked module tree is left alone"
rm -rf "$tmp/elsewhere"
pass "an upgrade, a reinstall, an owned or intervening tree (said why), no kernel-modules-hook, or DTBS not from the -ARCH default moves nothing"

downgraded
TEST_RSYNC_FAILS=1 retire_hook
(( retire_status == 1 )) && grep -Fq "nothing was removed" "$tmp/retire.err" && [[ -d $modules/$running && -f $modules/$running/vmlinuz ]] ||
  fail "a failed copy fails the hook and removes nothing" "status $retire_status: $(cat "$tmp/retire.err")"
pass "a failed copy removes nothing"

# As root, which pacman hooks always are, a fixture root is never honoured.
grep -Fq '(( EUID != 0 )) && [[ -n ${OMARCHY_SAVED_MODULES_ROOT:-} ]]' "$retire" ||
  fail "only an unprivileged caller can point the script at another root"
pass "only an unprivileged caller can point the script at another root"
