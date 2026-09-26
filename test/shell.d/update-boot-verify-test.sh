#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/fixtures/sudo-boundary-test.sh"

# omarchy update's boot checks through the real omarchy-update-boot, dispatcher
# and platform detector, inside the sudo boundary fixture: every other update
# step is a stub that records itself, and sudo records its arguments. A fake
# boot package's update-preflight and update-verify record themselves and exit
# with the status they are given.
require_platform_fixtures "omarchy update's boot checks on platform fixtures"

copy_boundary_file bin/omarchy-update
rm "$SUDO_TEST_ROOT/bin/omarchy-update-boot"
for command in omarchy-update-boot omarchy-lifecycle-dispatch omarchy-hw-platform; do
  ln -s "$ROOT/bin/$command" "$SUDO_TEST_ROOT/bin/$command"
done
export OMARCHY_UPDATE_LOGGED=1

tmp=$boundary_tmp/boot
mkdir -p "$tmp"
for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$tmp/$platform" "$platform"
done

# A lifecycle root whose update-preflight and update-verify exit with $2 and $3.
boot_package() {
  local lifecycle=$1 preflight=$2 verify=$3
  rm -rf "$lifecycle"
  mkdir -p "$lifecycle/usr/lib/omarchy/mac-boot"
  printf '#!/bin/bash\necho update-preflight >>%q\nexit %s\n' "$tmp/boot-ran" "$preflight" >"$lifecycle/usr/lib/omarchy/mac-boot/update-preflight"
  printf '#!/bin/bash\necho update-verify >>%q\necho "the boot files do not match" >&2\nexit %s\n' "$tmp/boot-ran" "$verify" \
    >"$lifecycle/usr/lib/omarchy/mac-boot/update-verify"
  chmod 755 "$lifecycle"/usr/lib/omarchy/mac-boot/*
  chmod -R go-w "$lifecycle"
}
boot_package "$tmp/passing" 0 0
boot_package "$tmp/failing" 9 9
boot_package "$tmp/refusing" 1 0
boot_package "$tmp/unverified" 0 1
mkdir -p "$tmp/none" "$tmp/older/usr/lib/omarchy/mac-boot" "$tmp/older/var/lib/pacman/local/omarchy-mac-boot-20260921-10"

# omarchy update -y on platform $1 with the boot package in lifecycle root $2.
# The update's own PATH is fixed, so the platform's uname goes beside the
# stubbed steps.
run_update() {
  local platform=$1 lifecycle=$2
  reset_boundary
  rm -f "$tmp/boot-ran"
  cp "$tmp/$platform/bin/uname" "$SUDO_TEST_ROOT/bin/uname"
  status=0
  OMARCHY_PROC_ROOT="$tmp/$platform/proc" OMARCHY_LIFECYCLE_ROOT="$lifecycle" \
    "$SUDO_TEST_ROOT/bin/omarchy-update" -y >"$tmp/out" 2>"$tmp/err" || status=$?
}

# The line number of the first event in the sudo log that starts with $1.
at() {
  grep -n -m 1 -F -- "$1" "$SUDO_TEST_LOG" | cut -d: -f1
}

reboot_offered() {
  grep -q '^step:omarchy-update-restart --reboot-only' "$SUDO_TEST_LOG"
}

# x86, generic aarch64 and Qualcomm: both boot checks are no-ops, even with
# failing boot-package entrypoints on disk, and nothing asks for root.
for platform in generic generic-aarch64 qualcomm; do
  run_update "$platform" "$tmp/failing"
  (( status == 0 )) || fail "$platform: an update reports success" "status $status: $(cat "$tmp/err")"
  [[ ! -e $tmp/boot-ran ]] || fail "$platform: no boot-package entrypoint runs" "$(cat "$tmp/boot-ran")"
  ! grep -q 'omarchy-lifecycle-dispatch' "$SUDO_TEST_LOG" || fail "$platform: the boot checks ask for no root" "$(cat "$SUDO_TEST_LOG")"
  [[ ! -s $tmp/err ]] || fail "$platform: the boot checks print nothing" "$(cat "$tmp/err")"
  reboot_offered || fail "$platform: the reboot is offered" "$(cat "$SUDO_TEST_LOG")"
  assert_boundary_cold "$platform update"
done
pass "x86, generic aarch64 and Qualcomm updates are unchanged: no boot check runs, nothing asks for root and the reboot is offered"

# Apple: preflight runs before the keyring and packages change, under the
# update's one authorization, and verify once the last package step, AUR, is
# done, cold through the no-update wrapper, before the reboot offer.
run_update apple-silicon "$tmp/passing"
(( status == 0 )) || fail "apple: an update whose boot checks pass reports success" "status $status: $(cat "$tmp/err")"
[[ $(cat "$tmp/boot-ran") == $'update-preflight\nupdate-verify' ]] || fail "apple: preflight and verify each run once" "$(cat "$tmp/boot-ran")"
dev=$(at 'step:omarchy-update-dev') preflight=$(at 'sudo omarchy-lifecycle-dispatch update-preflight')
keyring=$(at 'step:omarchy-update-keyring') aur=$(at 'step:omarchy-update-aur-pkgs')
verify=$(at 'sudo -N omarchy-lifecycle-dispatch update-verify') hook=$(at 'step:omarchy-hook post-update')
[[ -n $dev && -n $preflight && -n $keyring && -n $aur && -n $verify && -n $hook ]] &&
  (( dev < preflight && preflight < keyring && hook < aur && aur < verify )) ||
  fail "apple: preflight follows the dev checkout and precedes the keyring under the update's authorization; verify follows AUR through the no-update wrapper" "$(cat "$SUDO_TEST_LOG")"
! grep -q '^sudo omarchy-lifecycle-dispatch update-verify' "$SUDO_TEST_LOG" || fail "apple: verification never uses a reusable timestamp" "$(cat "$SUDO_TEST_LOG")"
[[ $(sed -n "$((verify - 1))p;$((verify + 1))p" "$SUDO_TEST_LOG") == $'sudo -k\nsudo -k' ]] ||
  fail "apple: verification starts cold after AUR and sudo is revoked right after it" "$(cat "$SUDO_TEST_LOG")"
reboot_offered || fail "apple: a verified update offers the reboot"
assert_boundary_cold "apple update"
pass "apple: preflight and verify run as root through the boot package, and a verified update offers the reboot"

run_update apple-silicon "$tmp/refusing"
(( status != 0 )) || fail "apple: a refused preflight fails the update"
for step in omarchy-update-keyring omarchy-update-system-pkgs omarchy-migrate omarchy-hook; do
  ! grep -q "^step:$step" "$SUDO_TEST_LOG" || fail "apple: a refused preflight stops the update before $step"
done
assert_boundary_cold "apple refused preflight"
pass "apple: a refused preflight stops the update before any package changes"

# A failed verification lets the update finish its remaining steps, then fails
# it without offering the reboot.
run_update apple-silicon "$tmp/unverified"
(( status == 1 )) || fail "apple: a failed verification fails the update" "status $status: $(cat "$tmp/err")"
! reboot_offered || fail "apple: a failed verification offers no reboot"
grep -q '^step:omarchy-update-stay-awake stop' "$SUDO_TEST_LOG" ||
  fail "apple: after a failed verification Stay Awake is released" "$(cat "$SUDO_TEST_LOG")"
grep -q 'the boot files do not match' "$tmp/err" && grep -q 'The update is not finished' "$tmp/err" ||
  fail "apple: a failed verification says why, and that the update is not finished" "$(cat "$tmp/err")"
! grep -q 'Something went wrong during the update' "$tmp/out" "$tmp/err" || fail "apple: a failed verification is not reported as a crash"
assert_boundary_cold "apple failed verification"
pass "apple: a failed verification fails the update, explained, with no reboot offered"

# A Mac without the boot package at all predates it: the update warns that its
# boot files were not verified and finishes, asking for no root.
run_update apple-silicon "$tmp/none"
(( status == 0 )) && reboot_offered || fail "apple without the boot package: the update finishes and offers the reboot" "status $status: $(cat "$tmp/err")"
grep -q 'update-verify on apple-silicon needs omarchy-mac-boot' "$tmp/err" && grep -q 'The boot files were not verified' "$tmp/err" ||
  fail "apple without the boot package: the update says the boot files were not verified" "$(cat "$tmp/err")"
! grep -q 'omarchy-lifecycle-dispatch' "$SUDO_TEST_LOG" || fail "apple without the boot package: nothing asks for root"
pass "apple: without the boot package the update warns that the boot files were not verified"

# A boot package from before update-verify is one package update away.
run_update apple-silicon "$tmp/older"
(( status == 1 )) && ! reboot_offered || fail "apple: a boot package without update-verify fails the update" "status $status: $(cat "$tmp/err")"
grep -q 'which omarchy-mac-boot 20260921-10 does not provide; update omarchy-mac-boot' "$tmp/err" ||
  fail "apple: a boot package without update-verify is named with its version" "$(cat "$tmp/err")"
pass "apple: a boot package without update-verify fails the update and asks for its update"
