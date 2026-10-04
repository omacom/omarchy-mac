#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/test/fixtures/mac-migrate/lib.sh"

# bin/omarchy-mac-migrate moves a tester Mac (a quattro-upstream or convergence
# build, from a candidate set or the collaboration repository) onto Omarchy's
# official edge: the omarchy-dev pair, the Mac packages and the Aurora chain.

retired=FBD6874D423C418DDB6D143EECE19CDDE306DBD2

# A GRUB tester on the Asahi kernel with an encrypted root: runtime and
# settings 4.0.2-2 and a newer cursor-bin from the unsigned collaboration
# repository, omarchy-mac above the candidate's release; the signed candidate
# set as the administrator's target.
new_fixture() {
  local name=$1
  F=$tmp/$name
  R=$F/root
  rm -rf "$F"
  mkdir -p "$R"
  mkdir -p "$R/run/systemd/system" "$R/run/lock" "$R/var/tmp" "$R/proc/sys/kernel/random" "$R/etc/default" "$R/etc/omarchy-mac" \
    "$R/var/lib/pacman/local" "$R/var/lib/pacman/sync" "$R/var/cache/pacman/pkg" "$R/etc/pacman.d/gnupg" \
    "$R/usr/share/pacman/keyrings" "$R/usr/share/limine" "$R/boot/grub" "$R/boot/efi/EFI/BOOT" "$R/boot/efi/m1n1" \
    "$R/usr/lib/modules/6.19.1-asahi" "$R/usr/lib/modules/7.1.12-aurora" "$R/var/lib/omarchy/migrations"
  echo boot-1 >"$R/proc/sys/kernel/random/boot_id"
  echo 6.19.1-asahi >"$R/proc/sys/kernel/osrelease"
  echo linux-asahi >"$R/usr/lib/modules/6.19.1-asahi/pkgbase"
  echo linux-aurora >"$R/usr/lib/modules/7.1.12-aurora/pkgbase"
  echo "menuentry linux-asahi" >"$R/boot/grub/grub.cfg"
  echo grub >"$R/boot/efi/EFI/BOOT/BOOTAA64.EFI"
  echo m1n1 >"$R/boot/efi/m1n1/boot.bin"
  echo "limine 12.9" >"$R/usr/share/limine/BOOTAA64.EFI"
  echo "GRUB_CMDLINE_LINUX=\"rd.luks.name=abc=root\"" >"$R/etc/default/grub"
  echo "root UUID=abc none" >"$R/etc/crypttab"
  : >"$R/var/lib/omarchy/migrations/omarchy-aarch64-sync-pending"
  for keyring in archlinuxarm asahi-alarm omarchy; do
    : >"$R/usr/share/pacman/keyrings/$keyring.gpg"
  done
  echo 1111111111111111111111111111111111111111 >"$R/usr/share/pacman/keyrings/archlinuxarm-trusted"
  echo 2222222222222222222222222222222222222222 >"$R/usr/share/pacman/keyrings/asahi-alarm-trusted"
  : >"$R/usr/share/pacman/keyrings/omarchy-trusted"
  printf '%s f\n%s f\n%s f\n' 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 "$retired" \
    >"$R/etc/pacman.d/gnupg/keys"
  mkdir -p "$F/keyserver"
  : >"$F/keyserver/$official"

  cat >"$R/var/lib/pacman/local/packages" <<'LOCAL'
asahi-alarm-keyring 20250101-1
cursor-bin 3.20.17-1
hyprland 0.50-1
limine 12.9.0-1
linux-asahi 6.19.1-1
m1n1 1.5.0-1
omarchy 4.0.2-2
omarchy-mac 0.1.0-5.9
omarchy-settings 4.0.2-2
pacman 7.0.0-1
uboot-asahi 2026.01-1
widget-extra 1.0-1
LOCAL
  for file in omarchy-4.0.2-2-aarch64.pkg.tar.xz omarchy-settings-4.0.2-2-aarch64.pkg.tar.xz linux-asahi-6.19.1-1-aarch64.pkg.tar.zst \
    m1n1-1.5.0-1-aarch64.pkg.tar.zst uboot-asahi-2026.01-1-aarch64.pkg.tar.zst; do
    echo cached >"$R/var/cache/pacman/pkg/$file"
  done
  repo core <<<"pacman 7.0.0-1"
  printf 'hyprland 0.51-1\nlimine 12.9.0-1\n' | repo extra
  printf 'linux-asahi 6.19.1-1\nm1n1 1.5.0-1\nuboot-asahi 2026.01-1\nasahi-alarm-keyring 20250101-1\n' | repo asahi-alarm
  printf 'omarchy 4.0.2-1\nomarchy-settings 4.0.2-1\ncursor-bin 3.20.10-1\n' | repo omarchy-old
  repo omarchy <<'EDGE'
omarchy 4.0.4-1
omarchy-settings 4.0.4-1
omarchy-dev 4.0.0.r6713.ga85e29a-1
omarchy-settings-dev 4.0.0.r6713.ga85e29a-1
omarchy-mac 0.1.0-6
omarchy-mac-boot 20260927-1
omarchy-keyring 20251027-1
linux-aurora 7.1.12.aurora2-11
linux-aurora-headers 7.1.12.aurora2-11
m1n1-aurora 1.6.1.aurora1-3
uboot-asahi 2026.07.asahi2-4
limine-mkinitcpio-hook 1.39.0-2
cursor-bin 3.20.10-1
EDGE
  printf 'omarchy 4.0.2-2\nomarchy-settings 4.0.2-2\ncursor-bin 3.20.17-1\nwidget-extra 1.0-1\n' | repo omarchy-aarch64
  cp "$F/repos/omarchy-aarch64/omarchy-aarch64.db" "$R/var/lib/pacman/sync/"
  alarm_repos
  relations

  cat >"$R/etc/pacman.conf" <<CONF
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

# Arch Linux ARM and Asahi
[asahi-alarm]
Server = file://$F/repos/asahi-alarm

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[omarchy]
SigLevel = Optional TrustAll
Server = file://$F/repos/omarchy-old

[omarchy-aarch64]
SigLevel = Optional TrustAll
Server = file://$F/repos/omarchy-aarch64
CONF
  cp -r "$tmp/set" "$F/set"
  cat >"$R/etc/omarchy-mac/migration-target" <<TARGET
# The signed candidate set, with the edge repository for everything else.
format=1
type=candidate-set
channel=edge
server=file://$F/repos/omarchy
set=$F/set
fingerprint=$signer
TARGET
  echo apple-silicon >"$F/platform"
  echo "base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck" >"$F/hooks"
  printf '%s\n' "$R/boot/efi" >"$F/mounts"
  echo /dev/mapper/root >"$F/root-source"
  printf '/dev/mapper/root crypt btrfs\n/dev/nvme0n1p5 part crypto_LUKS\n/dev/nvme0n1 disk \n' >"$F/lsblk"
  : >"$F/pacman.log"
  : >"$F/boot.log"
}

# Everything a finished migration leaves that must not depend on how it got
# there: packages, configuration, keys, loader, records and backups.
outcome() {
  local state
  state=$(state_dir)
  cat "$R/var/lib/pacman/local/packages"
  sed "s|$F|FIXTURE|g" "$R/etc/pacman.conf"
  sort "$R/etc/pacman.d/gnupg/keys"
  cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI" "$R/etc/default/limine"
  ls "$R/var/lib/omarchy"
  ls "$R/var/lib/pacman/sync"
  [[ ! -e $R/var/lib/pacman/db.lck ]] && echo unlocked
  sed -n 's/^target=//p' "$state/complete"
  (cd "$state/backup" && find . -type f | LC_ALL=C sort && sed 's/^[0-9a-f]* //' SHA256SUMS)
  ls "$state"
  [[ ! -e $R/etc/systemd/system/omarchy-mac-migrate-verify.service ]] && echo "no unit"
}

# --- The whole transition --------------------------------------------------

new_fixture baseline
output=$(migrate run 2>&1) || fail "a tester migrates to its reboot" "$output"
grep -q "Reboot to finish the migration to candidate-set apple-test-fixture" <<<"$output" || fail "the run asks for a reboot" "$output"
[[ $(migrate status) == *"State: waiting for a reboot"* ]] || fail "status reports the pending reboot" "$(migrate status)"
grep -q "^systemctl enable omarchy-mac-migrate-verify.service" "$F/boot.log" || fail "the post-reboot check is enabled"
state=$(state_dir)
grep -q "^ExecStart=/var/lib/omarchy-mac/migration/tool/omarchy-mac-migrate verify$" "$R/etc/systemd/system/omarchy-mac-migrate-verify.service" &&
  cmp -s "$tool" "$state/tool/omarchy-mac-migrate" || fail "the unit runs the tool's own kept copy"
output=$(migrate verify 2>&1) || fail "verify before the reboot waits" "$output"
[[ ! -f $state/complete ]] || fail "nothing completes before the reboot"
pass "a GRUB tester is migrated up to its reboot, which it waits for"

expected_packages='asahi-alarm-keyring 20250101-1
cursor-bin 3.20.10-1
hyprland 0.51-1
limine 12.9.0-1
limine-mkinitcpio-hook 1.39.0-2
linux-aurora 7.1.12.aurora2-11
m1n1-aurora 1.6.1.aurora1-3
omarchy-dev 4.0.0.r7000.gabc-1.1
omarchy-keyring 20251027-1
omarchy-mac 0.1.0-11.1
omarchy-mac-boot 20261004-1.1
omarchy-settings-dev 4.0.0.r7000.gabc-1.1
pacman 7.0.0-1
uboot-asahi 2026.07.asahi2-4
widget-extra 1.0-1'
[[ $(cat "$R/var/lib/pacman/local/packages") == "$expected_packages" ]] ||
  fail "the transaction swaps the runtime for the omarchy-dev pair, replaces every same-name build, even higher ones, and swaps the Asahi kernel and m1n1" "$(cat "$R/var/lib/pacman/local/packages")"
grep -q "^transaction omarchy-mac-candidate/omarchy-dev omarchy-mac-candidate/omarchy-settings-dev omarchy-mac-candidate/omarchy-mac " "$F/pacman.log" ||
  fail "targets are named in the candidate repository" "$(grep transaction "$F/pacman.log")"
grep -q "^transaction .* cursor-bin asahi-alarm-keyring omarchy-keyring$" "$F/pacman.log" ||
  fail "a collaboration build the official repositories carry and the keyrings are named too" "$(grep transaction "$F/pacman.log")"
! grep -q "headers" "$F/pacman.log" || fail "no kernel headers are installed where there were none"
[[ $(grep -c '^transaction ' "$F/pacman.log") == 1 ]] || fail "one package transaction"
grep -q "^widget-extra 1.0-1$" "$state/plan/kept" || fail "a build with no official counterpart is kept and listed"
pass "one transaction moves to the omarchy-dev pair and replaces same-name candidates, including higher-versioned ones, and keeps what has no official build"

conf=$(sed "s|$F|FIXTURE|g" "$R/etc/pacman.conf")
expected_conf=$(OMARCHY_MAC_MIGRATE_ROOT=$R fixture=1 bash -c 'source <(sed -n "/^core_pacman_conf() {/,/^}/p" "$1"); core_pacman_conf "file://FIXTURE/repos/omarchy"' _ "$ROOT/migrate/src/target.sh" |
  sed "s|^Server = https://github.com/asahi-alarm.*|Server = file://FIXTURE/repos/asahi-alarm|")
[[ $conf == "$expected_conf" ]] || fail "pacman.conf is the core Apple Silicon configuration for the target" "$(diff <(echo "$expected_conf") <(echo "$conf"))"
! grep -q 'candidate\|IgnorePkg\|TrustAll\|omarchy-aarch64' "$R/etc/pacman.conf" || fail "no candidate repository, pin, guard or collaboration repository stays"
[[ ! -e $R/var/lib/pacman/sync/omarchy-aarch64.db && ! -e $R/var/lib/pacman/sync/omarchy-mac-candidate.db ]] ||
  fail "the retired and candidate databases are gone"
grep -q "^pacman-key --populate archlinuxarm asahi-alarm omarchy" "$F/pacman.log" || fail "the installed keyrings are populated"
grep -q "^pacman-key --recv-keys $official" "$F/pacman.log" && grep -q "^$official f" "$R/etc/pacman.d/gnupg/keys" ||
  fail "the missing Omarchy key is fetched by fingerprint and trusted"
! grep -q "^$retired " "$R/etc/pacman.d/gnupg/keys" || fail "the retired fork key is deleted"
! grep -q "$signer" "$R/etc/pacman.d/gnupg/keys" || fail "the candidate key never enters pacman's keyring"
pass "the core pacman configuration, official trust bootstrapped by fingerprint, legacy trust and candidates gone"

for file in installed etc.tar boot.tar esp.tar luks-header.img packages/omarchy-4.0.2-2-aarch64.pkg.tar.xz \
  packages/linux-asahi-6.19.1-1-aarch64.pkg.tar.zst packages/m1n1-1.5.0-1-aarch64.pkg.tar.zst SHA256SUMS; do
  [[ -f $state/backup/$file ]] || fail "the backup holds $file"
done
grep -q "^omarchy-mac 0.1.0-5.9$" "$state/backup/packages.missing" || fail "an uncached package is listed as missing from the backup"
(cd "$state/backup" && sha256sum -c --quiet SHA256SUMS) || fail "the backup's digests verify"
[[ $(stat -c %a "$state/backup") == 700 ]] || fail "the backup is readable by root only"
tar -xOf "$state/backup/esp.tar" ./EFI/BOOT/BOOTAA64.EFI | grep -qx grub || fail "the ESP backup predates the switch"
grep -q "^cryptsetup luksHeaderBackup /dev/nvme0n1p5 " "$F/pacman.log" || fail "the LUKS header of the root partition is backed up"
pass "packages, /etc, /boot, the ESP and the LUKS header are backed up before anything changes"

[[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" && -e $R/var/lib/omarchy/limine.enabled ]] ||
  fail "Limine takes the loader slot"
[[ $(grep -E '^(update-m1n1|update-grub|boot-check pending --boot-chain linux-aurora|dispatch setup-boot|limine-boot activate|dispatch setup-system|dispatch update-verify)' "$F/boot.log" | tr '\n' '|') == \
  "update-m1n1 |update-grub |boot-check pending --boot-chain linux-aurora|dispatch setup-boot|limine-boot activate|boot-check pending --boot-chain linux-aurora|dispatch setup-system|boot-check pending --boot-chain linux-aurora|dispatch update-verify|" ]] ||
  fail "m1n1 and U-Boot are rebuilt and checked, the new runtime's setup-boot activates Limine, then setup-system and update-verify run" "$(cat "$F/boot.log")"
pass "the boot chain is rebuilt and checked, and the new runtime's setup-boot, setup-system and update-verify run before the reboot"

reboot_into_aurora
output=$(migrate verify 2>&1) || fail "the post-reboot verification completes the migration" "$output"
[[ -f $state/complete && ! -e $state/reboot-pending && ! -e $state/cache ]] || fail "completion retires the working state"
grep -q "^boot-check --boot-chain linux-aurora$" "$F/boot.log" || fail "the booted chain passes the full boot check"
[[ $(grep -c '^dispatch update-verify' "$F/boot.log") == 2 ]] || fail "update-verify runs again after the reboot"
grep -q "^systemctl disable omarchy-mac-migrate-verify.service" "$F/boot.log" && [[ ! -e $R/etc/systemd/system/omarchy-mac-migrate-verify.service && ! -e $state/tool ]] ||
  fail "the post-reboot unit and the tool's copy go"
[[ ! -e $R/var/lib/omarchy/migrations/omarchy-aarch64-sync-pending ]] || fail "the collaboration repository's marker is retired"
[[ $(migrate status) == *"State: complete"* ]] || fail "status reports completion"
baseline=$(outcome)
pass "after the reboot, Aurora through Limine is verified and compatibility state is retired"

output=$(migrate run 2>&1) || fail "a second run succeeds" "$output"
grep -q "Already migrated to candidate-set apple-test-fixture" <<<"$output" || fail "a second run says it is done" "$output"
[[ $(outcome) == "$baseline" ]] || fail "a second run changes nothing"
rm -rf "$state"
output=$(migrate run 2>&1) || fail "a Mac already on the target set passes" "$output"
grep -q "already runs the target set" <<<"$output" && [[ ! -e $state/journal ]] || fail "a Mac already on the target set is left alone" "$output"
pass "the migration is idempotent"

new_fixture check
digest=$(fixture_digest)
output=$(migrate check 2>&1) || fail "check passes on a Mac ready to migrate" "$output"
grep -q "Ready: run moves this Mac (tester, grub boot, encrypted) onto candidate-set apple-test-fixture" <<<"$output" ||
  fail "check says what run would do" "$output"
[[ $(fixture_digest) == "$digest" && ! -e $(state_dir)/journal ]] && ! grep -q '^transaction\|^pacman-key' "$F/pacman.log" ||
  fail "check changes nothing"
pass "check runs preflight alone and changes nothing"

# --- Interruption at every journal step ---------------------------------------

interrupt() { # when step
  local when=$1 step=$2 status=0 output last transactions=1
  new_fixture "kill-$when-$step"
  output=$(migrate_env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$step" -- run 2>&1) || status=$?
  if (( status == 0 )); then
    reboot_into_aurora
    output=$(migrate_env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$step" -- verify 2>&1) || status=$?
  fi
  (( status == 137 )) || fail "the run is killed $when $step" "status $status: $output"
  last=$(tail -n 1 "$(state_dir)/journal" | cut -d' ' -f2-)
  if [[ $when == "after" ]]; then
    [[ $last == "${step%-leaf} done"* ]] || fail "the journal ends with $step done" "$last"
  else
    [[ $last == "${step%-leaf} begin"* ]] || fail "the journal ends with $step begun" "$last"
  fi
  finish
  [[ $(outcome) == "$baseline" ]] || fail "killed $when $step, the resumed migration ends where an uninterrupted one does" "$(diff <(echo "$baseline") <(outcome))"
  [[ $when$step == "midtransaction" ]] && transactions=2
  [[ $(grep -c '^transaction ' "$F/pacman.log") == "$transactions" ]] || fail "killed $when $step: $transactions package transaction(s)" "$(cat "$F/pacman.log")"
  [[ $(tail -n 1 < <(grep '^transaction \|^hooks' "$F/pacman.log")) == "hooks" ]] || fail "killed $when $step: the last transaction's hooks ran"
}

for step in "${steps[@]}"; do
  interrupt after "$step"
done
pass "a kill -9 between any two journal steps resumes to the same end, with one transaction"
for step in "${steps[@]}"; do
  interrupt during "$step"
done
pass "a kill -9 after any step's work but before its record resumes to the same end, with one transaction"
for step in backup keyring prefetch repositories transaction boot-chain loader loader-leaf defaults unpin reboot retire; do
  interrupt mid "$step"
done
pass "a kill -9 in the middle of any step resumes to the same end; pacman killed before its hooks runs the transaction again"

# After the repository switch a boot resumes the migration: the fork's own
# update may be gone with its packages.
for step in repositories transaction loader; do
  new_fixture "boot-resumes-$step"
  kill_after "$step"
  [[ -f $R/etc/systemd/system/omarchy-mac-migrate-verify.service ]] && grep -q "^systemctl enable omarchy-mac-migrate-verify" "$F/boot.log" ||
    fail "after $step the unit that resumes at boot is armed"
  output=$(migrate verify 2>&1) || fail "after $step a boot resumes the migration" "$output"
  grep -q "Reboot to finish" <<<"$output" || fail "after $step the boot's run reaches the reboot" "$output"
done
new_fixture boot-before-switch
kill_after prefetch
[[ ! -e $R/etc/systemd/system/omarchy-mac-migrate-verify.service ]] || fail "before the switch no unit is armed"
output=$(migrate verify 2>&1) && [[ -z $output ]] || fail "before the switch a boot does nothing" "$output"
pass "from the repository switch on, the next boot resumes an unfinished migration"

# --- The guard while the transaction is pending ----------------------------------

new_fixture guard
kill_after repositories
guarded=$(cat "$R/etc/pacman.conf")
grep -q "^# omarchy-mac-migrate: a migration to Omarchy's packages is in progress." <<<"$guarded" ||
  fail "the switched configuration carries the guard" "$guarded"
ignore=$(sed -n 's/^IgnorePkg = //p' <<<"$guarded")
for name in omarchy-dev omarchy-settings-dev omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi limine-mkinitcpio-hook omarchy omarchy-settings linux-asahi m1n1 limine asahi-scripts mkinitcpio; do
  [[ " $ignore " == *" $name "* ]] || fail "the guard holds $name back" "$ignore"
done
pass "between the switch and the end of setup, a plain pacman -Syu leaves every package the migration changes alone"
for step in transaction boot-chain loader defaults verify; do
  new_fixture "guard-$step"
  kill_after "$step"
  grep -q "^IgnorePkg = " "$R/etc/pacman.conf" || fail "after $step the guard stays"
done
new_fixture guard-unpin
kill_after unpin
! grep -q "IgnorePkg" "$R/etc/pacman.conf" || fail "after unpin the guard is gone"
pass "the guard stays through setup and verification and goes once they pass"

# A test image's pin stays until the transaction is done, then goes with the guard.
new_fixture pinned-image
pin_mark="# Test image only (omarchy-mac-installer image-builder): keeps the candidate set's runtime,"
sed -i "/^\[options\]$/a $pin_mark\n# whose version sorts below the channel's. Keep these three lines.\nIgnorePkg = omarchy omarchy-mac omarchy-settings" "$R/etc/pacman.conf"
kill_after repositories
grep -Fq "$pin_mark" "$R/etc/pacman.conf" && grep -q "^IgnorePkg = omarchy omarchy-mac omarchy-settings$" "$R/etc/pacman.conf" ||
  fail "the test image's pin stays beside the guard" "$(cat "$R/etc/pacman.conf")"
finish
! grep -q "IgnorePkg\|Test image only" "$R/etc/pacman.conf" || fail "the pin goes once the migration is set up" "$(cat "$R/etc/pacman.conf")"
pass "a test image's pin stays until the new packages are set up, and goes with the guard"

# An administrator's own options and repositories stay.
new_fixture admin-options
sed -i '/^\[options\]$/a IgnorePkg = firefox\nNoExtract = usr/share/help/*' "$R/etc/pacman.conf"
printf '\n[custom]\nServer = file://%s/repos/custom\n' "$F" >>"$R/etc/pacman.conf"
repo custom <<<"widget-custom 1.0-1"
finish
grep -qx "IgnorePkg = firefox" "$R/etc/pacman.conf" && grep -qx "NoExtract = usr/share/help/\*" "$R/etc/pacman.conf" &&
  grep -qx "\[custom\]" "$R/etc/pacman.conf" || fail "an administrator's options and repositories are kept" "$(cat "$R/etc/pacman.conf")"
[[ $(grep -c '^IgnorePkg' "$R/etc/pacman.conf") == 1 ]] || fail "only the administrator's IgnorePkg stays"
pass "an administrator's own options and repositories stay in the core configuration"

# --- Preflight refusals ---------------------------------------------------------

new_fixture refusals
sed -i '/^omarchy /d' "$R/var/lib/pacman/local/packages"
refused "Omarchy 3.x" "upgrade the 3.x install with omarchy-upgrade-to-quattro-mac first"
new_fixture refusals
echo "base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems fsck" >"$F/hooks"
refused "busybox encrypt" "busybox encrypt"
new_fixture refusals
printf '\n[custom]\nSigLevel = Optional TrustAll\nServer = file:///custom\n' >>"$R/etc/pacman.conf"
refused "an unknown TrustAll repository" "\[custom\] accepts untrusted packages"
new_fixture refusals
printf '\n[custom]\nInclude = /etc/pacman.d/custom\n' >>"$R/etc/pacman.conf"
printf 'SigLevel = Optional TrustAll\nServer = file:///custom\n' >"$R/etc/pacman.d/custom"
refused "a TrustAll repository an Include configures" "\[custom\] accepts untrusted packages"
new_fixture refusals
sed -i '/^\[options\]$/a IgnorePkg = omarchy-mac*' "$R/etc/pacman.conf"
refused "an administrator's pin on a target" "holds back omarchy-mac, which the migration changes"
new_fixture refusals
sed -i '/^\[options\]$/a NoExtract = usr/bin/omarchy-lifecycle-*' "$R/etc/pacman.conf"
refused "a NoExtract that drops the dispatcher" "NoExtract or NoUpgrade (usr/bin/omarchy-lifecycle-\*) .* keeps usr/bin/omarchy-lifecycle-dispatch"
new_fixture refusals
sed -i '/^\[options\]$/a Include = /etc/pacman.d/extra-options' "$R/etc/pacman.conf"
refused "an Include in [options]" "an Include in \[options\]"
new_fixture refusals
: >"$R/var/lib/pacman/db.lck"
refused "a pacman lock" "pacman is busy"
new_fixture refusals
echo "/boot/initramfs-linux-asahi.img does not hold the 6.19.1 modules" >"$F/boot-check-fail"
refused "incoherent boot files" "boot files are not coherent"
grep -q "^boot-check pending --boot-chain$" "$F/boot.log" || fail "preflight checks the installed boot chain, not the running kernel" "$(cat "$F/boot.log")"
new_fixture refusals
mkdir -p "$R/var/lib/omarchy/mac-first-boot"
: >"$R/var/lib/omarchy/mac-first-boot/pending"
refused "an unfinished first boot" "first boot has not finished"
new_fixture refusals
echo "linux-aurora 7.1.11-1" >>"$R/var/lib/pacman/local/packages"
refused "two kernels" "expected one Apple kernel"
new_fixture refusals
rm "$R/etc/default/grub"
refused "no GRUB defaults" "no /etc/default/grub"
new_fixture refusals
rm "$R/usr/share/pacman/keyrings/asahi-alarm.gpg"
refused "no Asahi keyring" "asahi-alarm-keyring is not installed"
new_fixture refusals
rmdir "$R/run/systemd/system"
refused "an image build" "not a booted system"
new_fixture refusals
mkdir -p "$R/sys/class/power_supply/macsmc-battery" "$R/sys/class/power_supply/macsmc-ac"
echo Battery >"$R/sys/class/power_supply/macsmc-battery/type"
echo 12 >"$R/sys/class/power_supply/macsmc-battery/capacity"
echo Mains >"$R/sys/class/power_supply/macsmc-ac/type"
echo 0 >"$R/sys/class/power_supply/macsmc-ac/online"
refused "a low battery" "battery is below 30%"
echo 1 >"$R/sys/class/power_supply/macsmc-ac/online"
output=$(migrate run 2>&1) || fail "a low battery on the charger migrates" "$output"
new_fixture refusals
: >"$F/df-low"
refused "no space" "needs .* MiB free"
new_fixture refusals
: >"$F/mounts"
refused "no system ESP" "system ESP is not mounted at /boot/efi"
new_fixture refusals
head -c 16 /dev/urandom >>"$F/set/$(jq -r '.packages[2].filename' "$F/set/manifest.json")"
refused "a tampered candidate package" "does not verify: omarchy-mac-.* is missing or changed"
new_fixture refusals
sed -i "s/^fingerprint=.*/fingerprint=$other/" "$R/etc/omarchy-mac/migration-target"
refused "a set signed by another key" "does not verify: its key is not $other"
new_fixture refusals
resign_set "$F/set" "$tmp/other"
refused "a set re-signed by an untrusted key" "does not verify: its key is not $signer"
new_fixture refusals
resign_set "$F/set" "$tmp/other"
cat "$tmp/signer.asc" >>"$F/set/candidate-signing-key.asc"
refused "a receipt signed by another key in the key file" "does not verify: signing.json is not signed by $signer"
new_fixture refusals
cat "$tmp/other.asc" >>"$F/set/candidate-signing-key.asc"
package=$(jq -r '.packages[1].filename' "$F/set/manifest.json")
rm "$F/set/$package.sig"
gpg --batch --homedir "$tmp/other" --detach-sign --no-armor -o "$F/set/$package.sig" "$F/set/$package" 2>/dev/null
refused "a package signed by another key in the key file" "does not verify: $package is not signed by $signer"
new_fixture refusals
jq '.packages |= map(select(.name != "uboot-asahi"))' "$F/set/manifest.json" >"$F/manifest" && mv "$F/manifest" "$F/set/manifest.json"
refused "a changed manifest" "signing.json does not bind this manifest"
new_fixture refusals
rm "$F/keyserver/$official"
refused "an unreachable Omarchy key" "cannot fetch and trust the Omarchy packaging key"
pass "preflight refuses unsupported cohorts, legacy unlock, untrusted or pinning configurations, busy or incoherent systems, low power or space and unverifiable sets, changing nothing"

# A key whose signing subkey made the signatures is named by its primary fingerprint.
mkdir -m 700 "$tmp/subkey-home"
gpg --batch --homedir "$tmp/subkey-home" --pinentry-mode loopback --passphrase '' --quick-gen-key "Migration test subkey" ed25519 cert 1d 2>/dev/null
subkey_primary=$(gpg --batch --homedir "$tmp/subkey-home" --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
gpg --batch --homedir "$tmp/subkey-home" --pinentry-mode loopback --passphrase '' --quick-add-key "$subkey_primary" ed25519 sign 1d 2>/dev/null
new_fixture subkey
rm -rf "$F/set"
make_set "$F/set" "$tmp/subkey-home"
sed -i "s/^fingerprint=.*/fingerprint=$subkey_primary/" "$R/etc/omarchy-mac/migration-target"
output=$(migrate run 2>&1) || fail "a set signed by the pinned key's signing subkey verifies" "$output"
grep -q "Reboot to finish" <<<"$output" || fail "the subkey-signed set migrates to its reboot" "$output"
pass "signatures count only when the pinned key (or its signing subkey) made them, whatever else the key file holds"

new_fixture elsewhere
echo generic-aarch64 >"$F/platform"
output=$(migrate run 2>&1) || fail "another platform is a no-op" "$output"
grep -q "Not an Apple Silicon Mac" <<<"$output" && [[ ! -e $(state_dir) ]] || fail "another platform is left alone" "$output"
if OMARCHY_MAC_MIGRATE_ROOT="" "$tool" run 2>/dev/null; then fail "a normal user without a fixture root is refused"; fi
pass "other platforms and unprivileged callers change nothing"

new_fixture target-trust
chmod 666 "$R/etc/omarchy-mac/migration-target"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 75 )) && grep -q "refusing the target" <<<"$output" && [[ ! -e $(state_dir)/journal ]] || fail "a target others can write is refused, deferred with nothing changed" "$output"
chmod 644 "$R/etc/omarchy-mac/migration-target"
chmod 777 "$F/set"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 75 )) || fail "a candidate directory others can write is refused" "$output"
pass "target files and candidate sets must be writable by their owner only"

# --- The channel ------------------------------------------------------------------

# Without an administrator's target, the Mac follows the channel its own
# configuration names, here the collaboration repository's edge lane.
channel_fixture() {
  new_fixture "$1"
  rm "$R/etc/omarchy-mac/migration-target"
  sed -i "s|^Server = file://$F/repos/omarchy-aarch64$|Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/${2:-edge}|" "$R/etc/pacman.conf"
}

channel_fixture no-channel
sed -i "s|^Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/.*|Server = https://example.org/elsewhere|" "$R/etc/pacman.conf"
refused "an unknown channel" "cannot tell which Omarchy channel this Mac follows"
channel_fixture stable stable
# Omarchy's stable channel today: no Mac packages.
printf 'omarchy 4.0.4-1\nomarchy-settings 4.0.4-1\nomarchy-keyring 20251027-1\n' | repo official-stable omarchy
refused "the stable channel without Mac packages" "the stable channel has no omarchy-mac for Apple Silicon yet"
output=$(migrate run 2>&1 || true)
grep -q "The stable channel has no Mac release yet" <<<"$output" || fail "the deferral says why" "$output"
[[ $(migrate status) == *"The last run deferred: "*"stable channel has no omarchy-mac"* ]] || fail "status says why it deferred" "$(migrate status)"
channel_fixture edge-lane edge
cp -r "$F/repos/omarchy" "$F/repos/official-edge"
archive omarchy-dev 4.0.0.r6713.ga85e29a-1
archive omarchy-mac-boot 20260927-1
output=$(migrate check 2>&1) || fail "an edge lane follows the edge channel" "$output"
grep -q "onto repository file://$F/repos/official-edge (edge)" <<<"$output" || fail "the edge lane's Mac moves to the edge channel" "$output"
pass "a Mac whose channel cannot be told, or has no Mac release, defers with nothing changed"

# A repository target whose archives are not ready for Macs yet.
repository_fixture() {
  new_fixture "$1"
  printf 'format=1\ntype=repository\nchannel=edge\nserver=file://%s/repos/omarchy\n' "$F" >"$R/etc/omarchy-mac/migration-target"
  archive omarchy-dev 4.0.0.r6713.ga85e29a-1
  archive omarchy-mac-boot 20260927-1
}
repository_fixture edge-old-runtime
make_archive omarchy-mac-boot 20260927-1 "$F/archives/omarchy-mac-boot"
printf 'pkgname = omarchy-dev\npkgver = 4.0.0.r6713.ga85e29a-1\n' >"$tmp/PKGINFO" && bsdtar -czf "$F/archives/omarchy-dev" -C "$tmp" --transform 's|PKGINFO|.PKGINFO|' PKGINFO 2>/dev/null ||
  (mkdir -p "$tmp/old" && cp "$tmp/PKGINFO" "$tmp/old/.PKGINFO" && bsdtar -czf "$F/archives/omarchy-dev" -C "$tmp/old" .PKGINFO)
refused "a runtime without the dispatcher" "has no omarchy-lifecycle-dispatch"
repository_fixture edge-old-boot
mkdir -p "$tmp/oldboot/usr/lib/omarchy-mac/boot" "$tmp/oldboot/usr/lib/omarchy/mac-boot"
printf 'pkgname = omarchy-mac-boot\npkgver = 20260927-1\n' >"$tmp/oldboot/.PKGINFO"
: >"$tmp/oldboot/usr/lib/omarchy-mac/boot/migrate-engine.sh"
: >"$tmp/oldboot/usr/lib/omarchy/mac-boot/setup-boot"
: >"$tmp/oldboot/usr/lib/omarchy/mac-boot/update-verify"
bsdtar -czf "$F/archives/omarchy-mac-boot" -C "$tmp/oldboot" .PKGINFO usr
refused "an omarchy-mac-boot with its own migration engine" "not built from omacom/omarchy-mac-pkgs yet"
repository_fixture edge-ready
output=$(migrate run 2>&1) || fail "a ready repository target migrates" "$output"
grep -q "^omarchy-dev 4.0.0.r6713.ga85e29a-1$" "$R/var/lib/pacman/local/packages" && grep -q "^omarchy-mac-boot 20260927-1$" "$R/var/lib/pacman/local/packages" ||
  fail "the official builds replace higher-versioned tester builds" "$(cat "$R/var/lib/pacman/local/packages")"
grep -q "^transaction omarchy/omarchy-dev omarchy/omarchy-settings-dev omarchy/omarchy-mac omarchy/omarchy-mac-boot omarchy/linux-aurora omarchy/m1n1-aurora omarchy/uboot-asahi omarchy/limine-mkinitcpio-hook cursor-bin asahi-alarm-keyring omarchy-keyring$" "$F/pacman.log" ||
  fail "each official package is named in [omarchy]" "$(grep transaction "$F/pacman.log")"
grep -q "^download omarchy-dev \|^download omarchy-mac-boot " "$F/pacman.log" || fail "preflight reads the verified archives"
pass "a channel is ready for Macs only when its signed archives carry the dispatcher and a boot package without its own migration engine"

# --- Failures after preflight --------------------------------------------------

new_fixture removal
echo "omarchy-mac-boot widget-extra" >>"$F/conflicts"
conf_before=$(cat "$R/etc/pacman.conf")
packages_before=$(cat "$R/var/lib/pacman/local/packages")
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 75 )) && grep -q "would also remove widget-extra; nothing was changed" <<<"$output" || fail "an unexpected removal stops the rehearsal, deferred" "status $status: $output"
[[ $(cat "$R/etc/pacman.conf") == "$conf_before" && $(cat "$R/var/lib/pacman/local/packages") == "$packages_before" ]] ||
  fail "the repositories and packages are untouched after a failed rehearsal"
[[ ! -e $(state_dir)/journal && -n $(ls -d "$(state_dir)"/history/aborted-* 2>/dev/null) ]] || fail "the attempt is set aside, so the next run starts over"
[[ $(migrate status) == *"would also remove widget-extra"* ]] || fail "status says why it deferred" "$(migrate status)"
pass "a rehearsal that would remove more than the plan allows defers before the switch, and the next run starts over"

new_fixture after-boundary
kill_after repositories
: >"$F/fail-transaction"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && [[ -f $(state_dir)/journal ]] || fail "a failure after the switch is a failure, never a deferral" "status $status: $output"
rm "$F/fail-transaction"
finish
pass "after the repository switch a failure stops the migration for the next run to resume"

new_fixture loader
: >"$F/limine-activation-fail"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "Limine could not be activated; GRUB is still the loader" <<<"$output" || fail "a failed Limine activation fails the step" "$output"
[[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "grub" && ! -e $R/var/lib/omarchy/limine.enabled ]] || fail "a failed activation leaves GRUB as the loader"
rm "$F/limine-activation-fail"
finish
[[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" ]] || fail "the retried loader step activates Limine"
pass "a failed Limine activation leaves GRUB active, and the retry finishes"

new_fixture update-verify
kill_after defaults
echo "the UKI does not hold the 7.1.12 modules" >"$F/update-verify-fail"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "update-verify does not pass" <<<"$output" || fail "a failing update-verify stops before the reboot" "$output"
! grep -q "^systemctl enable omarchy-mac-migrate-verify.service$" <(grep -A100 'dispatch update-verify' "$F/boot.log" | tail -n +2) || true
grep -q "^IgnorePkg" "$R/etc/pacman.conf" || fail "the guard stays while verification fails"
rm "$F/update-verify-fail"
finish
pass "update-verify must pass before the reboot is offered, and after it"

new_fixture aborted-boot
output=$(migrate run 2>&1) || fail "the migration reaches its reboot" "$output"
echo boot-2 >"$R/proc/sys/kernel/random/boot_id"
status=0
output=$(migrate verify 2>&1) || status=$?
(( status == 1 )) && grep -q "this boot runs 6.19.1-asahi, not linux-aurora 7.1.12-aurora" <<<"$output" || fail "a boot of the old kernel fails verification" "$output"
[[ ! -f $(state_dir)/complete && -e $(state_dir)/reboot-pending ]] || fail "an unverified boot retires nothing"
pass "a reboot that did not come up on Aurora is not accepted"

new_fixture busy
kill_after backup
printf 'format=1\ntype=repository\nchannel=stable\nserver=file://%s/repos/omarchy\n' "$F" >"$F/stable-target"
output=$(migrate run --target "$F/stable-target" 2>&1) && fail "another target is refused while one is in progress" "$output"
grep -q "a migration to candidate-set apple-test-fixture .* is in progress" <<<"$output" || fail "the refusal names the migration in progress" "$output"
pass "a migration in progress keeps its target"

new_fixture first-boot
: >"$F/scriptlet-arms-first-boot"
finish
[[ ! -e $R/var/lib/omarchy/mac-first-boot/pending ]] || fail "a first-boot marker armed by the transaction is removed"
pass "fresh-image first boot is never armed on an existing Mac"

new_fixture locked
kill_after keyring
journal_before=$(cat "$(state_dir)/journal")
exec 8>"$R/run/lock/omarchy-mac-migrate.lock"
flock -n 8
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 75 )) && grep -q "another migration run is in progress" <<<"$output" && [[ $(cat "$(state_dir)/journal") == "$journal_before" && -d $(state_dir)/backup ]] ||
  fail "a run that cannot take the lock before the switch defers and leaves the state alone" "status $status: $output"
exec 8>&-
kill_after repositories
exec 8>"$R/run/lock/omarchy-mac-migrate.lock"
flock -n 8
status=0
output=$(migrate verify 2>&1) || status=$?
(( status == 1 )) || fail "past the switch, a run that cannot take the lock fails" "status $status: $output"
exec 8>&-
finish
pass "a second run never touches the state of the run holding the lock"

# --- The tool that resumes ----------------------------------------------------------

new_fixture handover
kill_after transaction
copy=$(state_dir)/tool/omarchy-mac-migrate
cmp -s "$tool" "$copy" || fail "the migration keeps a copy of the tool"
sed 's/^tool_version=1$/tool_version=99/' "$tool" >"$F/newer" && chmod 755 "$F/newer"
output=$(OMARCHY_MAC_MIGRATE_ROOT=$R MIGRATE_FIXTURE=$F OMARCHY_MAC_MIGRATE_ASAHI_SERVER="file://$F/repos/asahi-alarm" PATH="$stubs:$PATH" "$F/newer" run 2>&1) ||
  fail "a newer tool resumes the migration" "$output"
cmp -s "$F/newer" "$copy" || fail "a newer tool of the same journal format becomes the kept copy"
new_fixture handback
kill_after transaction
sed -i 's/^tool_version=1$/tool_version=99/' "$(state_dir)/tool/omarchy-mac-migrate"
output=$(migrate run 2>&1) || fail "an older tool hands the migration to the copy that started it" "$output"
grep -q "Resuming with the tool this migration started with (version 99)" <<<"$output" || fail "the hand-over is said" "$output"
pass "a migration resumes with the tool that started it, unless a newer one of the same journal format takes over"

# --- The system moving under a migration --------------------------------------

# omarchy update runs pacman -Syu before the migration resumes.
for step in prefetch repositories; do
  new_fixture "moved-$step"
  kill_after "$step"
  sed -i 's/^hyprland .*/hyprland 0.52-1/' "$R/var/lib/pacman/local/packages"
  finish
  grep -q "^hyprland 0.52-1$" "$R/var/lib/pacman/local/packages" || fail "after $step, the upgrade in between is kept"
  grep -q " prefetch reset " "$(state_dir)/journal" || fail "after $step, the changed system is rehearsed again" "$(cat "$(state_dir)/journal")"
  [[ $(grep -c '^transaction ' "$F/pacman.log") == 1 ]] || fail "after $step, one transaction"
done
pass "an update between the rehearsal and the transaction sends the migration back to rehearse, instead of sticking"

new_fixture frozen-databases
kill_after keyring
printf 'hyprland 0.53-1\nlimine 12.9.0-1\n' >"$F/repos/extra/extra.db"
finish
grep -q "^hyprland 0.51-1$" "$R/var/lib/pacman/local/packages" || fail "the transaction installs what preflight read, not a newer sync"
pass "the transaction installs the set preflight qualified, from the databases it froze"

new_fixture snapshot
kill_after keyring
echo "widget-conflict 1.0-1" >>"$R/var/lib/pacman/local/packages"
echo "omarchy-mac-boot widget-conflict" >>"$F/conflicts"
sed -i '/^widget-extra /d' "$R/var/lib/pacman/local/packages"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 75 )) && grep -q "would also remove widget-conflict; nothing was changed" <<<"$output" ||
  fail "a package installed after preflight is still guarded against removal" "$output"
! grep -q "remove widget-extra" <<<"$output" || fail "a package removed after preflight is not reported" "$output"
pass "the removal guard compares against what the rehearsal started from"

new_fixture held-lock
kill_after repositories
: >"$R/var/lib/pacman/db.lck"
mkdir -p "$R/proc/4242/fd"
ln -s "$R/var/lib/pacman/db.lck" "$R/proc/4242/fd/3"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "pacman is running (process 4242)" <<<"$output" && [[ -e $R/var/lib/pacman/db.lck ]] ||
  fail "a lock another package manager holds is left alone" "$output"
rm -rf "$R/proc/4242"
finish
pass "a held pacman lock stops the transaction; a stale one is cleared"

new_fixture resynced
kill_after repositories
printf 'hyprland 0.53-1\nlimine 12.9.0-1\n' >"$R/var/lib/pacman/sync/extra.db"
finish
grep -q "^hyprland 0.51-1$" "$R/var/lib/pacman/local/packages" || fail "a sync after the rehearsal does not change what the transaction installs"
new_fixture interrupted-then-moved
output=$(migrate_env OMARCHY_MAC_MIGRATE_KILL_MID=transaction -- run 2>&1) && fail "pacman is killed after its database write"
echo "late-extra 1.0-1" >>"$R/var/lib/pacman/local/packages"
finish
grep -q " prefetch reset " "$(state_dir)/journal" || fail "the changed packages are rehearsed again"
[[ $(grep -c '^transaction ' "$F/pacman.log") == 2 && $(grep '^transaction \|^hooks' "$F/pacman.log" | tail -n 1) == "hooks" ]] ||
  fail "a transaction killed before its hooks runs again after a new rehearsal" "$(cat "$F/pacman.log")"
pass "the transaction uses the rehearsed databases, and a killed one runs again even after a new rehearsal"

new_fixture frozen-set
kill_after preflight
head -c 16 /dev/urandom >>"$F/set/$(jq -r '.packages[3].filename' "$F/set/manifest.json")"
finish
mv "$F/set" "$F/set.gone"
output=$(migrate status) && [[ $output == *"State: complete"* ]] || fail "status needs no candidate set"
pass "after preflight only the verified copy of the set is used, and the original may change or go"

new_fixture enable
: >"$F/systemctl-fail"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "cannot install omarchy-mac-migrate-verify.service" <<<"$output" || fail "a unit that cannot be enabled fails the run" "$output"
rm "$F/systemctl-fail"
finish
pass "the unit that resumes the migration must be enabled before the switch goes ahead"

# --- A fresh install's defaults ----------------------------------------------------

user_unit() { # name target
  mkdir -p "$R/usr/lib/systemd/user"
  printf '[Unit]\nDescription=%s\n\n[Install]\nWantedBy=%s\n' "$1" "$2" >"$R/usr/lib/systemd/user/$1"
}

# Two users: one who has used Omarchy, with a unit enabled, one masked and one
# installed and turned off; one account Omarchy never ran for.
new_fixture defaults
printf 'root:x:0:0::/root:/bin/bash\ntester:x:1000:1000::/home/tester:/bin/bash\nguest:x:1001:1001::/home/guest:/bin/bash\n' >"$R/etc/passwd"
home=$R/home/tester
mkdir -p "$home/.local/state/omarchy" "$home/.config/systemd/user/graphical-session.target.wants" "$R/home/guest"
for unit in bt-agent.service omarchy-sleep-lock.service omarchy-migrate-notify.service omarchy-fcitx5.service; do
  user_unit "$unit" graphical-session.target
done
user_unit omarchy-recover-internal-monitor.service graphical-session-pre.target
ln -s /usr/lib/systemd/user/bt-agent.service "$home/.config/systemd/user/graphical-session.target.wants/bt-agent.service"
ln -s /dev/null "$home/.config/systemd/user/omarchy-fcitx5.service"
echo "zram-generator 1.2-1" >>"$R/var/lib/pacman/local/packages"
echo "avd-fw 0.1-1" >>"$F/repos/asahi-alarm/asahi-alarm.db"
echo "libva-v4l2_request-avd 1.0-1" >>"$F/repos/omarchy/omarchy.db"
echo "obs-studio 32.0-1" >>"$F/repos/extra/extra.db"
kill_after preflight
# The target's omarchy brings units this Mac never had.
user_unit omarchy-brightness-keyboard-auto.service graphical-session.target
user_unit omarchy-crash-watch.service graphical-session.target
user_unit owed.service graphical-session.target
output=$(migrate_env OMARCHY_MAC_MIGRATE_KILL_MID=defaults -- run 2>&1) && fail "the run is killed in the middle of its defaults"
grep -q "Installing the default packages a fresh install has: avd-fw libva-v4l2_request-avd" <<<"$output" || fail "the missing Apple defaults are named" "$output"
grep -q "No repository carries these default packages, so they stay missing: .*widevine" <<<"$output" ||
  fail "defaults no repository carries are named, not fatal" "$output"
finish
[[ $(grep -c '^transaction avd-fw libva-v4l2_request-avd$' "$F/pacman.log") == 1 ]] ||
  fail "the missing Apple defaults are installed once, across a resumed step" "$(cat "$F/pacman.log")"
! grep -q "obs-studio\|zram-generator" <(grep '^transaction' "$F/pacman.log") || fail "the base list's applications and installed defaults are left alone"
grep -q "^dispatch setup-system" "$F/boot.log" || fail "the Mac services a fresh install enables are set up through the dispatcher"
wants=$home/.config/systemd/user/graphical-session.target.wants
for unit in omarchy-brightness-keyboard-auto.service omarchy-crash-watch.service owed.service; do
  [[ $(readlink "$wants/$unit") == "/usr/lib/systemd/user/$unit" ]] || fail "a unit new to this Mac is enabled as first run does: $unit" "$(ls -la "$wants")"
done
[[ ! -e $wants/omarchy-sleep-lock.service && ! -L $wants/omarchy-sleep-lock.service ]] || fail "a unit the Mac had and the user turned off stays off"
[[ $(readlink "$home/.config/systemd/user/omarchy-fcitx5.service") == /dev/null && ! -L $wants/omarchy-fcitx5.service ]] || fail "a masked unit stays masked"
[[ $(readlink "$wants/bt-agent.service") == /usr/lib/systemd/user/bt-agent.service ]] || fail "an enabled unit is left as it is"
[[ ! -e $R/home/guest/.config ]] || fail "an account Omarchy never ran for is left alone"
[[ $(grep -c "^dispatch setup-user HOME=$home$" "$F/boot.log") -ge 1 ]] && ! grep -q "setup-user HOME=$R/home/guest\|setup-user HOME=$R/root" "$F/boot.log" ||
  fail "the Mac user setup runs through the dispatcher for each Omarchy user only" "$(grep setup-user "$F/boot.log")"
pass "a migrated Mac gains the Apple defaults, the Mac services and the user units a fresh install has, keeping every choice made"

new_fixture defaults-failing
echo "avd-fw 0.1-1" >>"$F/repos/asahi-alarm/asahi-alarm.db"
: >"$F/setup-system-fail"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "setup-system (omarchy-lifecycle-dispatch) could not set up the Mac's services" <<<"$output" || fail "a failed system setup fails the step" "$output"
[[ $(migrate status) == *"failed at defaults"* ]] || fail "status names the failed defaults" "$(migrate status)"
rm "$F/setup-system-fail"
finish
[[ $(grep -c '^transaction avd-fw$' "$F/pacman.log") == 1 ]] || fail "the retry installs nothing twice" "$(cat "$F/pacman.log")"
pass "a failed defaults step stops before the reboot and is retried"

first_run_units=$(git -C "$ROOT" show 69d80cccd:install/user/first-run/enable-user-units.sh 2>/dev/null | sed -n '/systemctl --user enable --now/,/[^\\]$/p' | grep -o '[a-z0-9-]*\.service' | xargs || true)
engine_units=$(sed -n 's/^fresh_user_units="\(.*\)"$/\1/p' "$ROOT/migrate/src/engine.sh")
if [[ -n $first_run_units ]]; then
  [[ $first_run_units == "$engine_units" ]] || fail "the migration enables the user units upstream's first run enables" "first run: $first_run_units; migration: $engine_units"
  pass "the migration's user units are upstream first run's"
fi

# --- Repairs the runtime's Mac migrations made --------------------------------------

broadcom_block="# Broadcom's firmware supplicant and authenticator fail the WPA four-way
# handshake on Apple hardware, which surfaces as a rejected password. Disable
# both so wpa_supplicant performs the handshake instead.
options brcmfmac feature_disable=0x82000"

# Two Omarchy users, one from quattro-upstream and one from mx-mac; alarm still
# in wheel beside the owner; the Intel Broadcom block after an owner's line; LANG=C.
repairs_fixture() {
  new_fixture "$1"
  printf 'root:x:0:0::/root:/bin/bash\nalarm:x:1000:1000::/home/alarm:/bin/bash\ntester:x:1001:1001::/home/tester:/bin/bash\nother:x:1002:1002::/home/other:/bin/bash\n' >"$R/etc/passwd"
  printf 'root:x:0:\nwheel:x:998:alarm,tester\nalarm:x:1000:\n' >"$R/etc/group"
  mkdir -p "$R/home/tester/.local/state/omarchy/migrations" "$R/home/other/.local/state/omarchy/migrations" "$R/home/alarm" "$R/etc/modprobe.d"
  : >"$R/home/tester/.local/state/omarchy/migrations/1789132067.sh"
  : >"$R/home/other/.local/state/omarchy/migrations/1790305681.sh"
  printf 'options brcmfmac roamoff=1\n%s\n' "$broadcom_block" >"$R/etc/modprobe.d/brcmfmac.conf"
  echo LANG=C >"$R/etc/locale.conf"
  printf '#en_US.UTF-8 UTF-8\n#de_DE.UTF-8 UTF-8\n' >"$R/etc/locale.gen"
  mkdir -p "$R/usr/share/omarchy/install/config"
  # The target runtime's leaf (omacom/omarchy #13362 69d80cccd).
  cp "$ROOT/test/fixtures/mac-migrate/runtime/install/config/locale.sh" "$R/usr/share/omarchy/install/config/locale.sh"
  cat >"$R/usr/share/omarchy/install/config/snapper.sh" <<'LEAF'
# Stands in for the runtime's Snapper leaf: its exit status is the fixture's.
echo "snapper-leaf OMARCHY_PATH=$OMARCHY_PATH" >>"$MIGRATE_FIXTURE/boot.log"
exit "$(cat "$MIGRATE_FIXTURE/snapper-status" 2>/dev/null || echo 0)"
LEAF
}

repaired_names="1789146110 1789148088 1789158179 1789172112 1790327324"

repairs_fixture repairs
kill_after preflight
output=$(migrate_env OMARCHY_MAC_MIGRATE_KILL_MID=broadcom -- run 2>&1) && fail "the run is killed in the middle of the Broadcom repair"
[[ -f $R/var/lib/omarchy/migrations/1789172112-initramfs-pending ]] || fail "the rebuild is owed before the Broadcom block goes"
finish
[[ $(<"$R/etc/modprobe.d/brcmfmac.conf") == "options brcmfmac roamoff=1" ]] || fail "only the Broadcom block goes" "$(cat "$R/etc/modprobe.d/brcmfmac.conf")"
[[ ! -e $R/var/lib/omarchy/migrations/1789172112-initramfs-pending && $(grep -c '^omarchy-mac-boot-update' "$F/boot.log") == 1 ]] ||
  fail "the boot image is rebuilt once, across the interrupted repair" "$(cat "$F/boot.log")"
[[ $(grep '^wheel:' "$R/etc/group") == "wheel:x:998:tester" ]] || fail "alarm leaves wheel beside another administrator" "$(cat "$R/etc/group")"
[[ $(<"$R/etc/locale.conf") == "LANG=en_US.UTF-8" ]] && grep -qx 'en_US.UTF-8 UTF-8' "$R/etc/locale.gen" || fail "a C locale becomes en_US.UTF-8" "$(cat "$R/etc/locale.conf" "$R/etc/locale.gen")"
grep -qx "snapper-leaf OMARCHY_PATH=$R/usr/share/omarchy" "$F/boot.log" || fail "the Snapper leaf runs" "$(cat "$F/boot.log")"
grep -qx 'omarchy-mac-setup-keyboard 3' "$F/boot.log" || fail "mx-mac's history names the generated keyboard line" "$(grep keyboard "$F/boot.log")"
for user in tester other; do
  for name in $repaired_names; do
    [[ -f $R/home/$user/.local/state/omarchy/migrations/$name.sh ]] || fail "$user has the repaired migration $name recorded as done"
  done
  [[ -f $R/home/$user/.local/state/omarchy/migrations/1785424256.sh ]] || fail "$user has systemd-oomd's migration settled (off on Macs)"
  [[ ! -e $R/home/$user/.local/state/omarchy/migrations/1790347292.sh ]] || fail "the retired platform migration is not recorded"
done
[[ ! -e $R/home/alarm/.local ]] || fail "an account Omarchy never ran for gets no records"
pass "the engine removes the Broadcom block, retires alarm from wheel, sets the locale, runs Snapper, hands over the keyboard, and settles those migrations"

# --- User setup that fails stays pending ------------------------------------------

new_fixture user-pending
printf 'tester:x:1000:1000::/home/tester:/bin/bash\n' >"$R/etc/passwd"
home=$R/home/tester
mkdir -p "$home/.local/state/omarchy" "$home/.config/systemd/user"
kill_after preflight
user_unit omarchy-crash-watch.service graphical-session.target
chmod 555 "$home/.config/systemd/user"
: >"$F/setup-user-fail"
output=$(migrate run 2>&1) || fail "user setup that fails does not stop the migration" "$output"
grep -q "Could not apply omarchy-crash-watch.service for tester" <<<"$output" && grep -q "Could not apply setup-user for tester" <<<"$output" ||
  fail "each failed item is reported" "$output"
[[ $(migrate status) == *"User setup pending"*"tester setup-user"* ]] || fail "status lists pending user setup" "$(migrate status)"
reboot_into_aurora
output=$(migrate verify 2>&1) || fail "verify completes the migration with user setup pending" "$output"
[[ -f $(state_dir)/complete && -s $(state_dir)/user-pending ]] || fail "the migration completes while user setup stays pending"
[[ -f $R/etc/systemd/system/omarchy-mac-migrate-verify.service && -x $(state_dir)/tool/omarchy-mac-migrate ]] ||
  fail "the unit and the tool's copy stay while user setup is pending"
chmod 755 "$home/.config/systemd/user"
rm "$F/setup-user-fail"
output=$(migrate verify 2>&1) || fail "a boot retries pending user setup" "$output"
[[ ! -e $(state_dir)/user-pending && ! -e $R/etc/systemd/system/omarchy-mac-migrate-verify.service && ! -e $(state_dir)/tool ]] ||
  fail "once nothing is pending the unit and the tool's copy go"
pass "a user's unit or setup that fails stays pending, runs again at each boot until it succeeds, then releases the unit"

# --- A tester already on Aurora and Limine ------------------------------------

# A converged test image (the M1 and M2 today): Aurora, m1n1-aurora, Limine in
# the slot, candidate builds, an unencrypted root.
new_fixture limine
sed -i -e 's/^linux-asahi .*/linux-aurora 7.1.12.aurora2-9/' -e 's/^m1n1 .*/m1n1-aurora 1.6.1.aurora1-2/' "$R/var/lib/pacman/local/packages"
echo 7.1.12-aurora >"$R/proc/sys/kernel/osrelease"
rm "$R/boot/grub/grub.cfg"
: >"$R/var/lib/omarchy/limine.enabled"
printf 'KERNEL_CMDLINE[default]="root=UUID=x"\n' >"$R/etc/default/limine"
echo "limine 12.8" >"$R/boot/efi/EFI/BOOT/BOOTAA64.EFI"
echo /dev/nvme0n1p5 >"$F/root-source"
printf '/dev/nvme0n1p5 part btrfs\n/dev/nvme0n1 disk \n' >"$F/lsblk"
finish
grep -q "^linux-aurora 7.1.12.aurora2-11$" "$R/var/lib/pacman/local/packages" || fail "the Aurora kernel moves to the target's build"
grep -q "^omarchy-mac-limine-cmdline" "$F/boot.log" && grep -q "^dispatch setup-boot" "$F/boot.log" && grep -q "^limine-boot activate" "$F/boot.log" ||
  fail "a Limine Mac rebuilds its menu and UKI, then the new setup-boot refreshes Limine" "$(cat "$F/boot.log")"
! grep -q "update-grub" "$F/boot.log" || fail "a Limine Mac does not touch GRUB" "$(cat "$F/boot.log")"
[[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" ]] || fail "the slot holds the packaged Limine"
[[ ! -e $(state_dir)/backup/luks-header.img ]] && ! grep -q cryptsetup "$F/pacman.log" || fail "an unencrypted root has no header to back up"
pass "a Limine tester on an unencrypted root keeps Limine, rebuilds its UKI and deploys the packaged loader"

# --- The build ------------------------------------------------------------------

"$ROOT/migrate/build" --check || fail "bin/omarchy-mac-migrate is built from migrate/src"
pass "the committed tool is what migrate/src builds"

# --- Fork leftovers ------------------------------------------------------------

leftover_copy() { # name: the bytes a fork wrote, from the tool itself
  bash -c "source <(sed -n '/^leftover() {/,/^}/p' \"\$1\"); leftover \"\$2\"" _ "$ROOT/migrate/src/repairs.sh" "$1"
}
new_fixture leftovers
printf 'tester:x:1000:1000::/home/tester:/bin/bash\n' >"$R/etc/passwd"
home=$R/home/tester
policies=$home/.config/wireplumber/wireplumber.conf.d
mkdir -p "$home/.local/state/omarchy" "$policies" "$R/etc/NetworkManager/conf.d" "$R/etc/modprobe.d" "$R/etc/systemd/system/suspend.target.wants"
leftover_copy wifi_backend.conf >"$R/etc/NetworkManager/conf.d/wifi_backend.conf"
printf 'options appledrm show_notch=0\n' >"$R/etc/modprobe.d/asahi-notch.conf"
leftover_copy omarchy-wifi-resume-fix.service >"$R/etc/systemd/system/omarchy-wifi-resume-fix.service"
ln -s /etc/systemd/system/omarchy-wifi-resume-fix.service "$R/etc/systemd/system/suspend.target.wants/omarchy-wifi-resume-fix.service"
leftover_copy asahi-headset-mic.conf >"$policies/asahi-headset-mic.conf"
leftover_copy asahi-audio-no-suspend-overlay.conf >"$policies/asahi-audio-no-suspend.conf"
finish
[[ ! -e $R/etc/NetworkManager/conf.d/wifi_backend.conf && -f $R/etc/NetworkManager/conf.d/wifi_backend.conf.omarchy-mac-retired ]] ||
  fail "a byte-identical Wi-Fi backend copy retires"
[[ $(<"$R/etc/modprobe.d/asahi-notch.conf") == "options appledrm show_notch=0" && ! -e $R/etc/modprobe.d/asahi-notch.conf.omarchy-mac-retired ]] ||
  fail "an edited copy stays"
[[ ! -e $R/etc/systemd/system/omarchy-wifi-resume-fix.service &&
  $(readlink "$R/etc/systemd/system/suspend.target.wants/omarchy-wifi-resume-fix.service") == /usr/lib/systemd/system/omarchy-wifi-resume-fix.service ]] ||
  fail "the fork's resume unit retires and its enablement points at the vendor unit"
[[ ! -e $policies/asahi-headset-mic.conf && -f $policies/asahi-headset-mic.conf.omarchy-mac-retired &&
  ! -e $policies/asahi-audio-no-suspend.conf && -f $policies/asahi-audio-no-suspend.conf.omarchy-mac-retired ]] ||
  fail "the user's copied WirePlumber policies retire, either revision of mx-mac's speaker policy" "$(ls -la "$policies")"
pass "the fork's byte-identical leftovers retire, keeping a backup; edited copies stay"
new_fixture leftovers-backup
mkdir -p "$R/etc/NetworkManager/conf.d"
leftover_copy wifi_backend.conf >"$R/etc/NetworkManager/conf.d/wifi_backend.conf"
printf 'administrator backup\n' >"$R/etc/NetworkManager/conf.d/wifi_backend.conf.omarchy-mac-retired"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "wifi_backend.conf.omarchy-mac-retired differs" <<<"$output" || fail "a different backup stops the step and says why" "$output"
[[ $(<"$R/etc/NetworkManager/conf.d/wifi_backend.conf.omarchy-mac-retired") == "administrator backup" ]] || fail "the administrator's backup is kept"
rm "$R/etc/NetworkManager/conf.d/wifi_backend.conf.omarchy-mac-retired"
finish
pass "a backup that differs is never overwritten: the step stops until it is moved"
