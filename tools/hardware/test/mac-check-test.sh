#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
if (( $(bash -c 'echo "${BASH_VERSINFO[0]}"') < 5 )); then
  pass "mac-check runs on the Mac's bash 5; skipping under an older bash"
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
fixture="$test_tmp/fixture"
kver=7.1.12-2-7-ARCH
uid=$(id -u)
mkdir -p "$stub_bin"

# A healthy M2 Max: Aurora kernel, Limine, a logged-in session.
make_fixture() {
  rm -rf "$fixture"
  local root=$fixture
  mkdir -p "$root/proc/device-tree" "$root/proc/asound" "$root/usr/lib/modules/$kver" "$root/var/lib/omarchy" \
    "$root/run/user/$uid/hypr/instance1" "$root/boot/efi/EFI/Linux" "$root/boot/efi/m1n1" "$root/.snapshots"
  printf 'apple,j416c\0apple,t6021\0apple,arm-platform\0' >"$root/proc/device-tree/compatible"
  printf 'Apple MacBook Pro (16-inch, M2 Max, 2023)\0' >"$root/proc/device-tree/model"
  printf ' 0 [AppleJ416HPAI  ]: aop_audio - MacBook Pro J416 HPAI\n                      MacBook Pro J416 High-Power Audio Interface\n 1 [AppleJ416      ]: macaudio - MacBook Pro J416\n                      MacBook Pro J416\n' >"$root/proc/asound/cards"
  printf 'cpu 1 2 3\nbtime 1790289337\n' >"$root/proc/stat"
  printf 'linux-aurora\n' >"$root/usr/lib/modules/$kver/pkgbase"
  printf 'kernel\n' >"$root/usr/lib/modules/$kver/vmlinuz"
  printf 'format=1\nsequence=56\ntag=asahi-quattro-59ee15f6\n' >"$root/var/lib/omarchy/asahi-quattro-release"
  printf 'format=1\nlane=rc\n' >"$root/var/lib/omarchy/apple-silicon-aurora-lane"
  : >"$root/run/user/$uid/hypr/instance1/.socket.sock"
  : >"$root/run/user/$uid/pipewire-0"
  : >"$root/run/user/$uid/bus"
  printf 'uki\n' >"$root/boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
  printf 'limine config\n' >"$root/boot/efi/limine.conf"
  printf 'm1n1 stage 2\n' >"$root/boot/efi/m1n1/boot.bin"
}

stub() {
  cat >"$stub_bin/$1"
  chmod +x "$stub_bin/$1"
}

stub uname <<'SH'
#!/bin/bash
case ${1:-} in
  -m) echo "${TEST_ARCH:-aarch64}" ;;
  -r) echo "${TEST_KVER:-7.1.12-2-7-ARCH}" ;;
  *) exec /usr/bin/uname "$@" ;;
esac
SH
stub pacman <<'SH'
#!/bin/bash
case $1 in
  -Qqo) [[ $2 == */usr/lib/modules/7.1.12-2-7-ARCH/vmlinuz && -e $2 ]] && echo linux-aurora || exit 1 ;;
  -Qq) printf '%s\n' linux-aurora linux-aurora-headers m1n1-aurora uboot-asahi limine omarchy-mac omarchy-mac-boot ;;
  -Q)
    case $2 in
      linux-aurora) echo "linux-aurora 7.1.12.aurora2-7" ;;
      *) echo "$2 1.0-1" ;;
    esac
    ;;
  -Si) [[ ${TEST_KERNEL_REPO:-omarchy} != none ]] && printf 'Repository      : %s\nName            : %s\n' "${TEST_KERNEL_REPO:-omarchy}" "$2" || exit 1 ;;
  *) exit 1 ;;
esac
SH
stub pacman-conf <<'SH'
#!/bin/bash
printf '%s\n' omarchy asahi-alarm core extra alarm
SH
stub sudo <<'SH'
#!/bin/bash
[[ $1 == "-n" ]] && shift
(( ${TEST_SUDO:-1} )) || exit 1
exec "$@"
SH
stub omarchy-apple-silicon-boot-check <<'SH'
#!/bin/bash
echo boot-check >>"$TEST_LOG"
if (( ${TEST_BOOT_CHECK_STATUS:-0} )); then
  echo "Apple Silicon boot check: m1n1/boot.bin on the system ESP is not m1n1 as installed" >&2
  exit 1
fi
echo "Apple Silicon boot check: running linux-aurora 7.1.12-2-7-ARCH from aurora-packages-3caea46 (lane=rc)"
SH
stub omarchy-mac-limine-active <<'SH'
#!/bin/bash
exit 0
SH
stub findmnt <<'SH'
#!/bin/bash
[[ ${*: -1} == */boot/efi ]] && echo vfat
SH
stub systemctl <<'SH'
#!/bin/bash
case "$*" in
  "--failed --no-legend --plain") printf '%s' "${TEST_FAILED_UNITS:-}" ;;
  "--user --failed --no-legend --plain") printf '%s' "${TEST_FAILED_USER_UNITS:-}" ;;
  "show -p LoadState --value omarchy-vendor-firmware.service") echo loaded ;;
  "show -p ActiveState --value omarchy-vendor-firmware.service") echo active ;;
  "show -p Result --value omarchy-vendor-firmware.service") echo success ;;
  "is-active speakersafetyd.service") echo active ;;
  *) exit 1 ;;
esac
SH
stub hyprctl <<'SH'
#!/bin/bash
[[ $HYPRLAND_INSTANCE_SIGNATURE == instance1 ]] || exit 1
echo '[{"name":"eDP-1","width":3456,"height":2160,"refreshRate":120.0},{"name":"USB-1","width":3440,"height":1440,"refreshRate":59.973}]'
SH
stub wpctl <<'SH'
#!/bin/bash
printf '  * node.description = "MacBook Pro J416 Speakers"\n  * node.name = "audio_effect.j416-convolver"\n'
SH
stub nmcli <<'SH'
#!/bin/bash
printf 'wlan0:wifi:%s\nlo:loopback:connected (externally)\n' "${TEST_WIFI_STATE:-connected}"
SH
stub NetworkManager <<'SH'
#!/bin/bash
printf '[device]\nwifi.backend=iwd\n'
SH
stub bluetoothctl <<'SH'
#!/bin/bash
printf 'Controller 00:00:00:00:00:00 (public)\n\tPowered: yes\n'
SH
stub timeout <<'SH'
#!/bin/bash
shift
exec "$@"
SH
stub btrfs <<'SH'
#!/bin/bash
[[ -d ${*: -1} ]]
SH
stub snapper <<'SH'
#!/bin/bash
printf 'number\n0\n1\n2\n'
SH
stub omarchy-migrate <<'SH'
#!/bin/bash
exit 1
SH
stub coredumpctl <<'SH'
#!/bin/bash
(( ${TEST_COREDUMPS:-0} )) || exit 1
echo '[{"exe":"/usr/bin/Hyprland","uid":958}]'
SH

run_check() {
  TEST_LOG="$test_tmp/calls.log" OMARCHY_HARDWARE_ROOT="$fixture" PATH="$stub_bin:$PATH" \
    bash "$TOOLS/mac-check" >"$test_tmp/out" 2>"$test_tmp/err"
}

fixture_state() {
  find "$fixture" -type f | sort | while IFS= read -r file; do
    printf '%s %s\n' "$(file_sha256 "$file")" "$file"
  done
}

make_fixture
before=$(fixture_state)
: >"$test_tmp/calls.log"
run_check || fail "a healthy Mac passes" "$(cat "$test_tmp/out" "$test_tmp/err")"
for line in \
  "PASS  kernel           running $kver from linux-aurora 7.1.12.aurora2-7" \
  "PASS  kernel-repo      linux-aurora updates from [omarchy]" \
  "PASS  boot-check       running linux-aurora 7.1.12-2-7-ARCH from aurora-packages-3caea46 (lane=rc)" \
  "PASS  displays         2 active: eDP-1 3456x2160@120, USB-1 3440x1440@60" \
  "PASS  sound-cards      AppleJ416HPAI, AppleJ416" \
  "PASS  default-sink     MacBook Pro J416 Speakers (audio_effect.j416-convolver)" \
  "PASS  snapshots        /.snapshots is a btrfs subvolume holding 2 snapshots" \
  "INFO  release          asahi-quattro-59ee15f6, Aurora lane rc" \
  "INFO  boot-file        $(file_sha256 "$fixture/boot/efi/EFI/Linux/omarchy_linux-aurora.efi")  /boot/efi/EFI/Linux/omarchy_linux-aurora.efi" \
  "INFO  boot-file        $(file_sha256 "$fixture/boot/efi/m1n1/boot.bin")  /boot/efi/m1n1/boot.bin" \
  "15 passed, 0 failed, 0 warnings, 0 skipped"; do
  grep -Fxq -- "$line" "$test_tmp/out" || fail "healthy report has: $line" "$(cat "$test_tmp/out")"
done
pass "a healthy Mac passes every check and prints its boot-file hashes"
[[ $(fixture_state) == "$before" ]] || fail "the check changes nothing on the Mac"
pass "the check changes nothing on the Mac"

: >"$test_tmp/calls.log"
if TEST_FAILED_UNITS=$'foo.service loaded failed failed Foo\n' TEST_FAILED_USER_UNITS=$'bar.service loaded failed failed Bar\n' \
  TEST_WIFI_STATE=disconnected TEST_BOOT_CHECK_STATUS=1 TEST_KERNEL_REPO=none run_check; then
  fail "failures make the check exit non-zero" "$(cat "$test_tmp/out")"
fi
for line in \
  "FAIL  units            failed: foo.service, user:bar.service" \
  "FAIL  wifi             wlan0 is disconnected" \
  "FAIL  boot-check       m1n1/boot.bin on the system ESP is not m1n1 as installed" \
  "FAIL  kernel-repo      no configured repository carries linux-aurora"; do
  grep -Fxq -- "$line" "$test_tmp/out" || fail "failing report has: $line" "$(cat "$test_tmp/out")"
done
pass "failed units, Wi-Fi, boot check and kernel repository are reported as failures"

rm "$fixture/boot/efi/EFI/Linux/omarchy_linux-aurora.efi" "$fixture/boot/efi/limine.conf"
run_check && fail "a Limine Mac without its boot files fails"
grep -Fxq "FAIL  boot-file        no unified kernel image under /boot/efi/EFI/Linux" "$test_tmp/out" || fail "a missing UKI is named" "$(cat "$test_tmp/out")"
grep -Fxq "FAIL  boot-file        /boot/efi/limine.conf is missing on a limine Mac" "$test_tmp/out" || fail "a missing limine.conf is named" "$(cat "$test_tmp/out")"
pass "a Limine Mac without its unified kernel image or limine.conf fails"
make_fixture

if TEST_KVER=7.1.13-1-ARCH run_check; then
  fail "a pending reboot fails the kernel check"
fi
grep -Fq "FAIL  kernel           running 7.1.13-1-ARCH does not belong to an installed kernel package" "$test_tmp/out" ||
  fail "the kernel check names the running kernel" "$(cat "$test_tmp/out")"
pass "a kernel that is not the installed package fails"

printf 'format=1\nlane=edge\nreboot_pending=abc:7.1.13-1-ARCH\n' >"$fixture/var/lib/omarchy/apple-silicon-aurora-lane"
: >"$test_tmp/calls.log"
run_check || fail "an open switch journal is not a failure" "$(cat "$test_tmp/out")"
grep -Fq "SKIP  boot-check       a kernel switch journal is open" "$test_tmp/out" || fail "an open journal skips the boot check"
! grep -q boot-check "$test_tmp/calls.log" || fail "the boot check does not run while a switch journal is open"
pass "an open kernel switch journal keeps the boot check from running"
make_fixture

: >"$test_tmp/calls.log"
TEST_SUDO=0 run_check || fail "no sudo is not a failure" "$(cat "$test_tmp/out")"
for id in boot-check boot-file snapshots; do
  grep -Eq "^SKIP  $id " "$test_tmp/out" || fail "without sudo $id is skipped" "$(cat "$test_tmp/out")"
done
! grep -q boot-check "$test_tmp/calls.log" || fail "the boot check does not run without sudo"
pass "root checks are skipped without passwordless sudo"

rm -rf "$fixture/run/user/$uid"
run_check || fail "no session is not a failure" "$(cat "$test_tmp/out")"
grep -Fxq "SKIP  displays         no Hyprland session; log in at the greeter first" "$test_tmp/out" || fail "no session skips displays"
grep -Fxq "SKIP  default-sink     no PipeWire session; log in at the greeter first" "$test_tmp/out" || fail "no session skips the default sink"
pass "session checks are skipped until someone logs in"
make_fixture

TEST_COREDUMPS=1 run_check || fail "coredumps are not a failure" "$(cat "$test_tmp/out")"
grep -Fq "INFO  coredumps        this boot: Hyprland (uid 958)" "$test_tmp/out" || fail "coredumps are listed" "$(cat "$test_tmp/out")"
pass "this boot's coredumps are listed for comparison"

printf 'qcom,x1e80100\0' >"$fixture/proc/device-tree/compatible"
status=0
run_check || status=$?
(( status == 2 )) || fail "a non-Apple machine exits 2" "status $status"
grep -Fq "not an Apple Silicon Mac" "$test_tmp/err" || fail "a non-Apple machine says why"
pass "a non-Apple machine is refused"
