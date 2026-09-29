#!/bin/bash
# omarchy update's boot verification running omarchy-mac-boot's real update-verify
# on a fixture Limine Mac: a coherent chain passes, an incoherent one fails the update.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"
source "$BOOT/test/fixtures/limine-mac.sh"

require_platform_fixtures "omarchy update's boot checks on platform fixtures"
require_command gzip
require_command b2sum

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Every step of omarchy update but its boot checks is a stub that records
# itself. The boot checks run the real omarchy-update-boot, dispatcher and
# platform detector; sudo passes the fixtures through.
steps=(
  omarchy-update-lock
  omarchy-update-requires-free-space
  omarchy-update-confirm
  omarchy-update-pkg-prune
  omarchy-snapshot
  omarchy-update-stay-awake
  omarchy-update-dev
  omarchy-update-keyring
  omarchy-update-system-pkgs
  omarchy-migrate
  omarchy-hook
  omarchy-update-aur-pkgs
  omarchy-update-mise
  omarchy-update-orphan-pkgs
  omarchy-update-analyze-logs
  omarchy-update-status
  omarchy-update-restart
)
stub_bin=$tmp/bin
mkdir -p "$stub_bin"
for step in "${steps[@]}"; do
  cat >"$stub_bin/$step" <<'SH'
#!/bin/bash
echo "${0##*/}" >>"$STEP_LOG"
SH
done
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
echo "$*" >>"$SUDO_LOG"
exec "$@"
SH
chmod +x "$stub_bin"/*

for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$tmp/$platform" "$platform"
done

# The whole update, as the stubs record it, before this change and with it on
# a platform whose boot checks are no-ops.
all_steps() {
  printf '%s\n' omarchy-update-lock omarchy-update-requires-free-space omarchy-update-pkg-prune omarchy-snapshot \
    omarchy-update-stay-awake omarchy-update-dev omarchy-update-keyring omarchy-update-system-pkgs omarchy-migrate \
    omarchy-hook omarchy-update-aur-pkgs omarchy-update-mise omarchy-update-orphan-pkgs omarchy-update-analyze-logs \
    omarchy-update-status omarchy-update-stay-awake omarchy-update-restart
}

# omarchy update -y on platform $1, with the boot package's entrypoints in the
# lifecycle root $2.
run_update() {
  local platform=$1 lifecycle=$2
  : >"$tmp/steps"
  : >"$tmp/sudo"
  set +e
  STEP_LOG="$tmp/steps" \
    SUDO_LOG="$tmp/sudo" \
    OMARCHY_UPDATE_LOGGED=1 \
    OMARCHY_PROC_ROOT="$tmp/$platform/proc" \
    OMARCHY_LIFECYCLE_ROOT="$lifecycle" \
    PATH="$tmp/$platform/bin:$stub_bin:$ROOT/bin:$PATH" \
    bash "$ROOT/bin/omarchy-update" -y >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
}

ran() {
  grep -Fxq "$1" "$tmp/steps"
}

# A lifecycle root holding entrypoints that record themselves and exit with $2.
recording_package() {
  local lifecycle=$1 code=$2 operation
  rm -rf "$lifecycle"
  mkdir -p "$lifecycle/usr/lib/omarchy/mac-boot"
  for operation in update-preflight update-verify; do
    printf '#!/bin/bash\necho %s >>%q\nexit %s\n' "$operation" "$tmp/boot-ran" "$code" >"$lifecycle/usr/lib/omarchy/mac-boot/$operation"
  done
  chmod -R go-w "$lifecycle"
  chmod 755 "$lifecycle"/usr/lib/omarchy/mac-boot/*
}

# omarchy-mac-boot's own update-verify, on the fixture Mac. The dispatcher runs
# entrypoints with an empty environment, so this one puts the fixture's back
# before it runs the real entrypoint and boot check. $1 is the running kernel.
mac_boot_package() {
  local lifecycle=$tmp/mac-boot entrypoint=$tmp/mac-boot/usr/lib/omarchy/mac-boot/update-verify
  rm -rf "$lifecycle"
  mkdir -p "${entrypoint%/*}"
  {
    printf '#!/bin/bash\n'
    limine_mac_env "$BOOT/bin" "${1:-}"
    printf 'exec bash %q\n' "$BOOT/entrypoints/update-verify"
  } >"$entrypoint"
  chmod -R go-w "$lifecycle"
  chmod 755 "$entrypoint"
}


# omarchy-mac-boot's update-verify on a Limine Mac, end to end.
limine_mac_init "$tmp/mac"
limine_mac
mac_boot_package
run_update apple-silicon "$tmp/mac-boot"
(( status == 0 )) || fail "apple: an update that leaves a coherent boot chain succeeds" "status $status: $(cat "$tmp/out" "$tmp/err")"
ran omarchy-update-restart || fail "apple: a verified update offers the reboot"
grep -Fq "running linux-aurora $mac_kver; installed boot files match" "$tmp/out" || fail "apple: the update shows what it verified" "$(cat "$tmp/out")"
mac_boot_package 6.16.0-aurora9-ARCH
run_update apple-silicon "$tmp/mac-boot"
(( status == 0 )) && ran omarchy-update-restart ||
  fail "apple: an update that installed a new kernel is verified before its reboot" "status $status: $(cat "$tmp/out" "$tmp/err")"
pass "apple: an update that leaves a coherent boot chain passes verification and offers the reboot"

# Injected incoherence: the update fails, says why and what to do, and does not
# offer the reboot. Everything else still runs.
blocked() {
  local description=$1 reason=$2
  run_update apple-silicon "$tmp/mac-boot"
  (( status == 1 )) || fail "apple: $description fails the update" "status $status: $(cat "$tmp/err")"
  ! ran omarchy-update-restart || fail "apple: $description offers no reboot"
  ran omarchy-update-analyze-logs && ran omarchy-update-status && (( $(grep -c '^omarchy-update-stay-awake$' "$tmp/steps") == 2 )) ||
    fail "apple: $description still checks the logs, refreshes the status and releases Stay Awake" "$(cat "$tmp/steps")"
  grep -Fq "$reason" "$tmp/err" || fail "apple: $description is explained" "$(cat "$tmp/err")"
  grep -Fq "do not reboot yet" "$tmp/err" && grep -Fq "The update is not finished" "$tmp/err" ||
    fail "apple: $description says the update is not finished and not to reboot" "$(cat "$tmp/err")"
}
mac_boot_package
limine_mac
limine_mac_dtb "$mac_root/opt/t8103-j274.dtb" "from another kernel"
limine_mac_boot_bin "$mac_root/usr/lib/asahi-boot/m1n1.bin" "${mac_dtbs[@]:0:2}" /opt/t8103-j274.dtb
blocked "a wrong device tree in m1n1/boot.bin" "m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1, linux-aurora $mac_kver's device trees"
limine_mac
printf 'm1n1 stage 2 from the previous m1n1-aurora\n' >"$tmp/m1n1.bin"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
blocked "a stale m1n1" "m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1"
limine_mac
rm "$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
blocked "a missing UKI" "/boot/efi/EFI/Linux/omarchy_linux-aurora.efi (the Limine UKI) is missing"
pass "apple: a wrong device tree, a stale m1n1 or a missing UKI fails the update, explained, with no reboot offered"
