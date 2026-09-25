#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

snapshot="$ROOT/bin/omarchy-snapshot"
restore="$ROOT/bin/omarchy-system-snapshot-restore"

grep -F 'omarchy-cmd-missing limine-snapper-restore' "$snapshot" >/dev/null ||
  fail "snapshot restore detects a missing Limine helper"
grep -F 'omarchy-system-snapshot-restore' "$snapshot" >/dev/null ||
  fail "snapshot restore falls back to the subvolume swap"
! grep -F 'omarchy-mac-snapshot-restore' "$snapshot" "$restore" >/dev/null ||
  fail "snapshot restore does not use the GRUB-era omarchy-mac-snapshot-restore"
grep -F 'subvol=/@' "$restore" >/dev/null ||
  fail "the fallback restore requires the @ subvolume layout"
grep -F 'btrfs subvolume snapshot' "$restore" >/dev/null ||
  fail "the fallback restore swaps a writable snapshot into @"
pass "snapshot restore uses Limine when present and the subvolume swap when not"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-cmd-missing" <<'SH'
#!/bin/bash
[[ $1 == limine-snapper-restore && ${LIMINE_RESTORE:-0} != 1 ]]
SH
# Not a Mac; snapshot-restore-mac-test.sh covers Macs.
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/omarchy-hw-apple-silicon"
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
SH
cat >"$stub_bin/limine-snapper-restore" <<'SH'
#!/bin/bash
printf 'limine-restore\n' >>"$TEST_LOG"
SH
cat >"$stub_bin/omarchy-system-snapshot-restore" <<'SH'
#!/bin/bash
printf 'subvol-restore\n' >>"$TEST_LOG"
SH
chmod +x "$stub_bin"/*

run_restore() {
  : >"$calls"
  LIMINE_RESTORE="$1" TEST_LOG="$calls" PATH="$stub_bin:$PATH" \
    bash "$snapshot" restore
}

run_restore 1
grep -Fx 'sudo limine-snapper-restore' "$calls" >/dev/null ||
  fail "Limine restore is used when the helper is present" "$(cat "$calls")"
! grep -q subvol-restore "$calls" || fail "the subvolume swap is not used when Limine is present"
pass "Limine restore is used when the helper is present"

run_restore 0
grep -Fx 'sudo omarchy-system-snapshot-restore' "$calls" >/dev/null ||
  fail "the subvolume swap is used when Limine is absent" "$(cat "$calls")"
! grep -q limine-restore "$calls" || fail "Limine restore is not used when the helper is absent"
pass "the subvolume swap is used when Limine is absent"

# The swap itself, against a scratch tree. btrfs is stubbed: "subvolume
# snapshot" copies, and "subvolume show" answers for directories carrying a
# marker file, which stands in for being a real subvolume. A snapshot of @ holds
# an empty directory where the nested .snapshots store was; the store itself
# must travel from the displaced root into the restored one.
swap_bin="$test_tmp/swap-bin"
mkdir -p "$swap_bin"
cat >"$swap_bin/btrfs" <<'SH'
#!/bin/bash
case "$1 $2" in
  "subvolume snapshot") cp -a "$3" "$4" ;;
  "subvolume show") [[ -f $3/.omarchy-test-subvolume ]] ;;
  *) exit 99 ;;
esac
SH
chmod +x "$swap_bin/btrfs"

# @ with a marker, a snapper store holding snapshot 1 whose contents differ from
# the live root, and the empty .snapshots placeholder inside that snapshot.
build_tree() {
  local top=$1
  rm -rf "$top"
  mkdir -p "$top/@/.snapshots/1/snapshot/.snapshots" "$top/@/.snapshots/1/snapshot/usr/share/omarchy"
  echo live >"$top/@/marker"
  echo snap >"$top/@/.snapshots/1/snapshot/marker"
  touch "$top/@/.snapshots/.omarchy-test-subvolume"
  printf '<snapshot><date>2026-09-12 10:00:00</date><description>pre-update</description></snapshot>\n' >"$top/@/.snapshots/1/info.xml"
}

run_swap() {
  local top=$1 source=$2
  PATH="$swap_bin:$PATH" bash -euo pipefail -c '
    source "$1"
    swap_root "$2" "$3" 123
    move_snapshot_store "$2" "@old-123" "@"
  ' _ "$restore" "$top" "$source" 2>&1
}

tree="$test_tmp/tree"
build_tree "$tree"
listing=$(PATH="$swap_bin:$PATH" bash -c 'source "$1"; list_store_snapshots "$2"' _ "$restore" "$tree")
[[ $listing == $'1\t2026-09-12 10:00:00\tpre-update' ]] ||
  fail "the rehearsal listing reads snapshot number, date and description off the store" "$listing"
pass "the rehearsal listing reads snapshots off the store"

run_swap "$tree" "@/.snapshots/1/snapshot" >"$test_tmp/swap.out" || fail "the swap succeeds" "$(cat "$test_tmp/swap.out")"
[[ $(cat "$tree/@/marker") == snap ]] || fail "@ now holds the chosen snapshot"
[[ $(cat "$tree/@old-123/marker") == live ]] || fail "the displaced root is kept as @old-<stamp>"
[[ ! -e $tree/@new ]] || fail "no @new is left behind"
[[ -f $tree/@/.snapshots/.omarchy-test-subvolume ]] || fail "the snapshot store is a subvolume under the restored root"
[[ $(cat "$tree/@/.snapshots/1/snapshot/marker") == snap ]] || fail "earlier snapshots are still in the store"
[[ ! -e $tree/@old-123/.snapshots ]] || fail "nothing nested stays in @old-<stamp>"
pass "the swap carries the snapper store into the restored root"

# A baseline like @fresh has no .snapshots at all: the store still comes across.
build_tree "$tree"
mkdir -p "$tree/@fresh"
echo fresh >"$tree/@fresh/marker"
run_swap "$tree" "@fresh" >"$test_tmp/swap.out" || fail "the baseline swap succeeds" "$(cat "$test_tmp/swap.out")"
[[ $(cat "$tree/@/marker") == fresh ]] || fail "@ now holds the baseline"
[[ -f $tree/@/.snapshots/.omarchy-test-subvolume ]] || fail "the store moves into a baseline that had none"
[[ ! -e $tree/@old-123/.snapshots ]] || fail "the store leaves the displaced root"
pass "restoring a baseline still carries the snapper store"

# Something other than the empty placeholder at the restored .snapshots is not
# ours to remove: the swap stands, the store stays put, and the caller is told.
build_tree "$tree"
echo stray >"$tree/@/.snapshots/1/snapshot/.snapshots/file"
if run_swap "$tree" "@/.snapshots/1/snapshot" >"$test_tmp/swap.out"; then
  fail "a non-empty .snapshots in the snapshot is refused"
fi
[[ $(cat "$tree/@/marker") == snap ]] || fail "the root swap still stands when the store move is refused"
[[ -f $tree/@old-123/.snapshots/.omarchy-test-subvolume ]] || fail "the store stays where it was when refused"
grep -q 'not the empty placeholder' "$test_tmp/swap.out" || fail "the refusal is explained" "$(cat "$test_tmp/swap.out")"
pass "a non-empty placeholder stops the store move without losing the store"

# The displaced root without a store (never had snapper) is left alone.
build_tree "$tree"
rm -rf "$tree/@/.snapshots"
mkdir -p "$tree/@fresh"
run_swap "$tree" "@fresh" >"$test_tmp/swap.out" || fail "a swap without a store succeeds" "$(cat "$test_tmp/swap.out")"
[[ ! -e $tree/@/.snapshots ]] || fail "no store is invented"
pass "a root without a snapper store swaps cleanly"

grep -F -- '--rehearse' "$restore" >/dev/null || fail "the restore has a rehearsal mode"
grep -F 'OMARCHY_SNAPSHOT_RESTORE_CHOICE' "$restore" >/dev/null || fail "rehearsal picks non-interactively"
pass "the restore can be rehearsed against a scratch filesystem"

# The swap runs inside an if in main, where errexit is off, so every step has
# to check itself. A failed snapshot must change nothing, a stale @new must be
# refused rather than promoted to the root, and a failed second rename must
# put the old root back.
fail_bin="$test_tmp/fail-bin"
mkdir -p "$fail_bin"
cat >"$fail_bin/btrfs" <<'SH'
#!/bin/bash
case "$1 $2" in
  "subvolume snapshot") [[ ${BTRFS_FAIL:-} != snapshot ]] || exit 1; cp -a "$3" "$4" ;;
  "subvolume show") [[ -f $3/.omarchy-test-subvolume ]] ;;
  *) exit 99 ;;
esac
SH
cat >"$fail_bin/mv" <<'SH'
#!/bin/bash
# Fail only the rename whose source is MV_FAIL_SRC, so the recovery rename that
# follows a failed one can still succeed.
[[ ${MV_FAIL_SRC:-} != "${@: -2:1}" ]] || exit 1
exec /usr/bin/mv "$@"
SH
chmod +x "$fail_bin"/*

run_swap_only() {
  local top=$1 source=$2
  PATH="$fail_bin:$PATH" bash -euo pipefail -c '
    source "$1"
    if swap_root "$2" "$3" 123; then echo swapped; else echo "refused $?"; fi
  ' _ "$restore" "$top" "$source" 2>&1
}

build_tree "$tree"
result=$(BTRFS_FAIL=snapshot run_swap_only "$tree" "@/.snapshots/1/snapshot")
grep -q '^refused' <<<"$result" || fail "a failed snapshot is reported" "$result"
[[ $(cat "$tree/@/marker") == live && ! -e $tree/@old-123 && ! -e $tree/@new ]] ||
  fail "a failed snapshot changes nothing" "$(ls "$tree")"
pass "a failed snapshot leaves the root untouched and reports failure"

build_tree "$tree"
mkdir -p "$tree/@new"
echo stale >"$tree/@new/marker"
result=$(run_swap_only "$tree" "@/.snapshots/1/snapshot")
grep -q '^refused' <<<"$result" && grep -q 'already exists' <<<"$result" || fail "a stale @new is refused" "$result"
[[ $(cat "$tree/@/marker") == live && ! -e $tree/@old-123 && $(cat "$tree/@new/marker") == stale ]] ||
  fail "a stale @new is never promoted to the root" "$(ls "$tree")"
pass "a stale @new is refused instead of becoming the root"

build_tree "$tree"
result=$(MV_FAIL_SRC="$tree/@new" run_swap_only "$tree" "@/.snapshots/1/snapshot")
grep -q '^refused' <<<"$result" || fail "a failed second rename is reported" "$result"
[[ $(cat "$tree/@/marker") == live ]] || fail "a failed second rename puts the old root back" "$(ls "$tree"; cat "$tree/@/marker" 2>/dev/null)"
[[ ! -e $tree/@old-123 ]] || fail "the moved-aside root is renamed back"
pass "a failed second rename restores the original root"

grep -Fq 'subvolid=5' "$restore" && grep -Fq 'filesystem behind /' "$restore" ||
  fail "the rehearsal refuses anything but a scratch filesystem's top level"
! grep -Fq 'uname -r' "$restore" || fail "the kernel check no longer trusts the running kernel"
grep -Fq 'warn_kernel_mismatch "$TOP" "@old-$stamp" "@"' "$restore" || fail "the kernel check reads the displaced root's installed kernels"
pass "rehearsal isolation and the boot-kernel check are in place"

rehearsal="$ROOT/test/manual/snapshot-restore-rehearsal.sh"
[[ -f $rehearsal ]] || fail "the loopback rehearsal lives in the repository"
grep -Fq 'set -euo pipefail' "$rehearsal" || fail "the rehearsal runs under errexit"
! grep -Eq '&& echo|&& printf' "$rehearsal" || fail "rehearsal checks are fatal, not echo-on-success"
grep -Fq -- '--rehearse "$mnt"' "$rehearsal" || fail "the rehearsal drives the real --rehearse mode"
pass "the loopback rehearsal is in the repository with fatal checks"

# The kernel on the ESP is whatever the displaced root installed. Warn when the
# restored root lacks modules for it, and warn just as loudly when it has no
# modules at all, which is the case the mismatch loop cannot see.
kernels_tree="$test_tmp/kernels"
kernel_warnings() {
  bash -c 'source "$1"; warn_kernel_mismatch "$2" "@old-1" "@"' _ "$restore" "$kernels_tree" 2>&1 >/dev/null
}
rm -rf "$kernels_tree"; mkdir -p "$kernels_tree/@old-1/usr/lib/modules/6.2.0-new" "$kernels_tree/@/usr/lib/modules/6.2.0-new"
[[ -z $(kernel_warnings) ]] || fail "matching module trees produce no warning" "$(kernel_warnings)"
rm -rf "$kernels_tree"; mkdir -p "$kernels_tree/@old-1/usr/lib/modules/6.2.0-new" "$kernels_tree/@/usr/lib/modules/6.1.0-old"
kernel_warnings | grep -q 'kernel on /boot is 6.2.0-new' || fail "a newer installed kernel without restored modules is warned about" "$(kernel_warnings)"
rm -rf "$kernels_tree"; mkdir -p "$kernels_tree/@old-1/usr/lib/modules/6.2.0-new" "$kernels_tree/@/usr"
kernel_warnings | grep -q 'no kernel modules' || fail "a restored root without modules is warned about" "$(kernel_warnings)"
pass "the kernel check warns on a mismatch and on a restored root with no modules"
