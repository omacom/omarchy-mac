#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/install-bcm43602-kernel.sh"
detector="$ROOT/bin/omarchy-hw-apple-bcm43602"
all="$ROOT/install/hardware/all.sh"
packages="$ROOT/install/omarchy-other.packages"
migration="$ROOT/migrations/1789274809.sh"

grep -Fq 'apple/install-bcm43602-kernel.sh' "$all" || fail "the BCM43602 kernel setup runs during hardware setup"
grep -Fxq 'linux-bcm43602' "$packages" || fail "the custom kernel is available to the offline installer"
grep -Fxq 'linux-bcm43602-headers' "$packages" || fail "the custom kernel headers are available to the offline installer"
! grep -Eq 'omarchy-pkg-drop|pacman[[:space:]]+-R' "$leaf" || fail "the stock kernel remains installed as a fallback"
grep -Fq 'install-bcm43602-kernel.sh' "$migration" || fail "existing installations reuse the hardware setup leaf"
pass "the kernel integration is wired into fresh and existing installations"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
installed="$test_tmp/installed"
limine_dir="$test_tmp/etc/limine-entry-tool.d"
limine_conf="$test_tmp/boot/limine.conf"
candidate_uki="$test_tmp/boot/EFI/Linux/omarchy_linux-bcm43602.efi"
stock_uki="$test_tmp/boot/EFI/Linux/omarchy_linux.efi"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf 'add' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
(( ${PACKAGE_ADD_FAIL:-0} == 0 )) || exit 1
printf '%s\n' linux-bcm43602 linux-bcm43602-headers >>"$INSTALLED_PACKAGES"
SH

cat >"$stub_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash
for package in "$@"; do
  grep -Fxq "$package" "$INSTALLED_PACKAGES" 2>/dev/null || exit 1
done
SH

cat >"$stub_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash
! omarchy-pkg-present "$@"
SH

cat >"$stub_bin/limine-mkinitcpio" <<'SH'
#!/bin/bash
printf 'limine-mkinitcpio\n' >>"$TEST_LOG"
(( ${LIMINE_FAIL:-0} == 0 )) || exit 1
mkdir -p "$(dirname "$LIMINE_CONF")" "$(dirname "$CANDIDATE_UKI")"
printf 'candidate\n' >"$CANDIDATE_UKI"
printf 'stock\n' >"$STOCK_UKI"
printf '%s\n' '/EFI/Linux/omarchy_linux-bcm43602.efi' '/EFI/Linux/omarchy_linux.efi' >"$LIMINE_CONF"
SH

cat >"$stub_bin/omarchy-state" <<'SH'
#!/bin/bash
printf 'state' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo\n' >>"$TEST_LOG"
"$@"
SH

cat >"$stub_bin/omarchy-hw-apple-bcm43602" <<'SH'
#!/bin/bash
source "$BCM43602_DETECTOR"
case ${1:-} in
  "") [[ ${TEST_HARDWARE_MATCH:-1} == 1 ]] ;;
  --ready) apple_bcm43602_ready ;;
  *) exit 2 ;;
esac
SH

chmod +x "$stub_bin"/*

pci='03:00.0 Network controller [0280]: Broadcom Inc. BCM43602 [14e4:43ba]
	Subsystem: Apple Inc. Device [106b:0133]'

fixture_env=(
  "OMARCHY_BCM43602_BOOT_AVAILABLE_KIB=524288"
  "OMARCHY_BCM43602_LIMINE_DIR=$limine_dir"
  "OMARCHY_BCM43602_LIMINE_CONF=$limine_conf"
  "OMARCHY_BCM43602_CANDIDATE_UKI=$candidate_uki"
  "OMARCHY_BCM43602_STOCK_UKI=$stock_uki"
  "TEST_LOG=$calls"
  "INSTALLED_PACKAGES=$installed"
  "LIMINE_CONF=$limine_conf"
  "CANDIDATE_UKI=$candidate_uki"
  "STOCK_UKI=$stock_uki"
  "BCM43602_DETECTOR=$detector"
  "PATH=$stub_bin:$ROOT/bin:$PATH"
)

reset_fixture() {
  : >"$calls"
  printf '%s\n' linux >"$installed"
  rm -rf "$test_tmp/boot" "$test_tmp/etc"
}

run_leaf() {
  env "${fixture_env[@]}" "$@" bash -euo pipefail "$leaf" </dev/null
}

reset_fixture
source "$detector"
apple_bcm43602_matches x86_64 'Apple Inc.' MacBookPro12,1 "$pci" || fail "the detector matches the live-tested hardware"
apple_bcm43602_matches aarch64 'Apple Inc.' MacBookPro12,1 "$pci" && fail "the detector rejects aarch64"
apple_bcm43602_matches x86_64 LENOVO MacBookPro12,1 "$pci" && fail "the detector rejects non-Apple hardware"
apple_bcm43602_matches x86_64 'Apple Inc.' MacBookPro11,4 "$pci" && fail "the detector rejects other Mac models"
apple_bcm43602_matches x86_64 'Apple Inc.' MacBookPro12,1 '14e4:43ba Subsystem: 106b:ffff' && fail "the detector rejects other subsystems"
apple_bcm43602_matches x86_64 'Apple Inc.' MacBookPro12,1 '14e4:43a0 Subsystem: 106b:0133' && fail "the detector rejects other chips"
pass "the package is limited to the live-tested hardware identity"

reset_fixture
run_leaf >/dev/null
grep -Fqx $'add\tlinux-bcm43602\tlinux-bcm43602-headers' "$calls" || fail "the tested Mac installs the custom kernel and matching headers" "$(cat "$calls")"
grep -Fxq 'limine-mkinitcpio' "$calls" || fail "the final boot policy is regenerated after installation"
env "${fixture_env[@]}" omarchy-hw-apple-bcm43602 --ready || fail "candidate and stock boot entries are verified"
pass "the tested Mac installs and verifies the candidate with stock fallback"

grep -Fxv linux "$installed" >"$installed.tmp"
mv "$installed.tmp" "$installed"
if env "${fixture_env[@]}" bash -c 'source "$BCM43602_DETECTOR"; apple_bcm43602_ready'; then
  fail "a stale stock UKI is not accepted without the stock Linux package"
fi
printf '%s\n' linux >>"$installed"
pass "readiness requires the stock Linux package"

: >"$calls"
run_leaf >/dev/null
[[ ! -s $calls ]] || fail "a complete setup is not changed on rerun" "$(cat "$calls")"
pass "the setup is idempotent"

rm -f "$limine_dir/zz-apple-bcm43602.conf" "$candidate_uki" "$limine_conf"
: >"$calls"
run_leaf >/dev/null
! grep -q '^add' "$calls" || fail "installed packages are not reinstalled during boot repair"
grep -Fxq 'limine-mkinitcpio' "$calls" || fail "missing boot state is regenerated"
env "${fixture_env[@]}" omarchy-hw-apple-bcm43602 --ready || fail "boot repair restores complete state"
pass "an interrupted post-install boot setup is repaired"

reset_fixture
if run_leaf OMARCHY_BCM43602_BOOT_AVAILABLE_KIB=131072 >/dev/null 2>&1; then
  fail "installation refuses insufficient boot space"
fi
[[ ! -s $calls ]] || fail "the package install does not start with insufficient boot space"
[[ ! -e $limine_dir/zz-apple-bcm43602.conf ]] || fail "boot order is unchanged when the space check fails"
pass "insufficient boot space fails before changing the system"

reset_fixture
if env "${fixture_env[@]}" -u OMARCHY_BCM43602_BOOT_AVAILABLE_KIB \
  OMARCHY_BCM43602_BOOT_PATH="$test_tmp/missing-boot" \
  bash -euo pipefail "$leaf" >/dev/null 2>&1; then
  fail "installation refuses an unreadable boot filesystem"
fi
[[ ! -s $calls ]] || fail "an unreadable boot filesystem is detected before package installation"
pass "boot-space detection fails closed"

reset_fixture
if run_leaf PACKAGE_ADD_FAIL=1 >/dev/null 2>&1; then
  fail "a package installation failure propagates"
fi
[[ ! -e $limine_dir/zz-apple-bcm43602.conf ]] || fail "boot order is unchanged when package installation fails"
pass "package installation failure remains retryable"

reset_fixture
if run_leaf LIMINE_FAIL=1 >/dev/null 2>&1; then
  fail "a Limine regeneration failure propagates"
fi
pass "boot generation failure remains retryable"

reset_fixture
env "${fixture_env[@]}" TEST_HARDWARE_MATCH=0 OMARCHY_PATH="$ROOT" bash -euo pipefail "$migration" >/dev/null
[[ ! -s $calls ]] || fail "unsupported hardware does not request elevation" "$(cat "$calls")"
pass "the migration checks hardware before elevation"

printf '%s\n' linux linux-bcm43602 linux-bcm43602-headers >"$installed"
: >"$calls"
env "${fixture_env[@]}" OMARCHY_PATH="$ROOT" bash -euo pipefail "$migration" >/dev/null
grep -Fxq 'sudo' "$calls" || fail "the migration repairs incomplete boot state"
grep -Fxq $'state\tset\treboot-required' "$calls" || fail "a repaired installation requests a reboot"
env "${fixture_env[@]}" omarchy-hw-apple-bcm43602 --ready || fail "the migration leaves complete boot state"
pass "existing installations repair interrupted setup and request reboot"

: >"$calls"
env "${fixture_env[@]}" OMARCHY_PATH="$ROOT" bash -euo pipefail "$migration" >/dev/null
[[ ! -s $calls ]] || fail "a complete migration does not elevate or request another reboot" "$(cat "$calls")"
pass "the migration is machine-idempotent"
