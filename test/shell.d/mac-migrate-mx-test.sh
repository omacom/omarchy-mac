#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/test/fixtures/mac-migrate/lib.sh"

# bin/omarchy-mac-migrate moves an mx-mac Mac, as the M1 Pro runs it, onto
# Omarchy's official packages: the fork's omarchy-dev pair and bundle, its
# signed [omarchy] and [omarchy-aurora] releases and keys, Aurora, Limine and
# an encrypted root. On edge the fork's omarchy-dev pair, which sorts above
# Omarchy's own dev builds, is downgraded to them by name in the one
# transaction. The fake pacman rejects a database beside a signature that does
# not match it, as pacman does.

fork_key=C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC
release_key=5983B1CA32CB778F4D74D24ECFF35022CA5B5959
fork_dev=4.0.4.r7081.gca187b0-1
official_dev=4.0.0.r6713.ga85e29a-1

# The signed candidate set: the edge pair and Mac set, a build below the fork's
# pinta and a package the Mac never had.
SET_EXTRA=$'pinta 3.1.2-1.1\navd-fw 0.1-1' make_set "$tmp/mx-set" "$tmp/signer"

# A fork release's database is signed; the signature matches only that database.
sign_repo() {
  local db=$F/repos/$1/$2.db
  echo "signed $(sha256sum "$db" | cut -d' ' -f1)" >"$db.sig"
}

# The fork's [omarchy] and [omarchy-aurora] release sections, as its channel
# updaters write them.
fork_pacman_conf() {
  cat <<CONF
[options]
HoldPkg = pacman glibc
Architecture = aarch64
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

# Aurora kernel and bootloader, kept on the qualified release by omarchy update
[omarchy-aurora]
SigLevel = Required DatabaseOptional
Server = file://$F/repos/omarchy-aurora

[omarchy]
SigLevel = Required DatabaseOptional
Server = file://$F/repos/omarchy-fork

[asahi-alarm]
SigLevel = Required DatabaseOptional
Server = file://$F/repos/asahi-alarm

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
CONF
}

# The fork's own omarchy update: its channel updaters point pacman.conf back at
# the fork's releases and sync them, and its keyring holds the fork's keys.
fork_update() {
  fork_pacman_conf >"$R/etc/pacman.conf"
  for name in omarchy-fork/omarchy omarchy-aurora/omarchy-aurora; do
    cp "$F/repos/$name.db" "$F/repos/$name.db.sig" "$R/var/lib/pacman/sync/"
  done
  grep -q "^$fork_key " "$R/etc/pacman.d/gnupg/keys" || echo "$fork_key f" >>"$R/etc/pacman.d/gnupg/keys"
}

# An mx-mac Mac as the M1 Pro runs it: the fork's runtime pair and bundle,
# Aurora and U-Boot from the fork's releases, Limine in the loader slot and the
# encrypted root unlocked by sd-encrypt. No omarchy-mac or omarchy-mac-boot is
# installed. Omarchy's edge [omarchy] carries the Mac set and its own dev pair;
# the administrator's target is the signed candidate set on edge.
new_fixture() {
  F=$tmp/$1
  R=$F/root
  rm -rf "$F"
  mkdir -p "$R/run/systemd/system" "$R/run/lock" "$R/var/tmp" "$R/proc/sys/kernel/random" "$R/etc/default" "$R/etc/omarchy-mac" \
    "$R/var/lib/pacman/local" "$R/var/lib/pacman/sync" "$R/var/cache/pacman/pkg" "$R/etc/pacman.d/gnupg" \
    "$R/usr/share/pacman/keyrings" "$R/usr/share/limine" "$R/boot/grub" "$R/boot/efi/EFI/BOOT" "$R/boot/efi/EFI/Linux" "$R/boot/efi/m1n1" \
    "$R/usr/lib/modules/7.1.12-aurora" "$R/var/lib/omarchy/mac-first-boot"
  echo boot-1 >"$R/proc/sys/kernel/random/boot_id"
  echo 7.1.12-aurora >"$R/proc/sys/kernel/osrelease"
  echo linux-aurora >"$R/usr/lib/modules/7.1.12-aurora/pkgbase"
  echo "limine 12.9" >"$R/usr/share/limine/BOOTAA64.EFI"
  cp "$R/usr/share/limine/BOOTAA64.EFI" "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI"
  echo uki >"$R/boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
  printf '/+Omarchy\n  //linux-aurora\n  path: boot():/EFI/Linux/omarchy_linux-aurora.efi#abc\n' >"$R/boot/efi/limine.conf"
  : >"$R/var/lib/omarchy/limine.enabled"
  printf 'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]="root=UUID=x rd.luks.name=abc=root"\n' >"$R/etc/default/limine"
  echo "menuentry linux-aurora" >"$R/boot/grub/grub.cfg"
  echo m1n1 >"$R/boot/efi/m1n1/boot.bin"
  echo "GRUB_CMDLINE_LINUX=\"rd.luks.name=abc=root\"" >"$R/etc/default/grub"
  echo "root UUID=abc none luks" >"$R/etc/crypttab"
  printf 'format=1\nsequence=57\ntag=asahi-quattro-ca187b0a\n' >"$R/var/lib/omarchy/asahi-quattro-release"
  printf 'format=1\nsequence=58\ntag=asahi-quattro-0123abcd\n' >"$R/var/lib/omarchy/asahi-quattro-release.pending"
  printf 'format=1\ntag=asahi-packages-stable-2949b88c\n' >"$R/var/lib/omarchy/asahi-package-repository"
  printf 'format=1\nchannel=aurora\nrelease_tag=aurora-packages-3caea469\n' >"$R/var/lib/omarchy/aurora-target.descriptor"
  printf 'format=1\nchannel=edge\nkernel=linux-aurora\n' >"$R/var/lib/omarchy/apple-silicon-channel"
  printf 'format=1\nlane=edge\n' >"$R/var/lib/omarchy/apple-silicon-aurora-lane"
  printf 'format=1\nencrypt=1\n' >"$R/var/lib/omarchy/mac-first-boot/install.conf"
  for keyring in archlinuxarm asahi-alarm omarchy; do
    : >"$R/usr/share/pacman/keyrings/$keyring.gpg"
  done
  echo 1111111111111111111111111111111111111111 >"$R/usr/share/pacman/keyrings/archlinuxarm-trusted"
  echo 2222222222222222222222222222222222222222 >"$R/usr/share/pacman/keyrings/asahi-alarm-trusted"
  echo "$official" >"$R/usr/share/pacman/keyrings/omarchy-trusted"
  printf '%s f\n' 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 "$official" "$fork_key" "$release_key" \
    >"$R/etc/pacman.d/gnupg/keys"
  mkdir -p "$F/keyserver"
  : >"$F/keyserver/$official"

  cat >"$R/var/lib/pacman/local/packages" <<LOCAL
asahi-alarm-keyring 20250101-1
dotnet-runtime 9.0.8.sdk100-1
hyprland 0.50-1
limine 12.9.0-1
limine-mkinitcpio-hook 1.36.0-3
linux-aurora 7.1.12.aurora2-7
linux-aurora-headers 7.1.12.aurora2-7
m1n1-aurora 1.6.1.aurora1-2
mise 2026.9.4-1
obs-studio 32.2.2-1
omarchy-dev $fork_dev
omarchy-keyring 20251027-1
omarchy-nvim 2026.8.1-3
omarchy-settings-dev $fork_dev
pacman 7.0.0-1
pinta 3.1.2-2
quickshell-git 0.3.0.r20.g28771c7-2
ttf-jetbrains-mono-nerd-basic 3.4.0-1
uboot-asahi 2026.07.asahi2-3
LOCAL
  for file in "omarchy-dev-$fork_dev-aarch64.pkg.tar.zst" "omarchy-settings-dev-$fork_dev-aarch64.pkg.tar.zst" \
    linux-aurora-7.1.12.aurora2-7-aarch64.pkg.tar.xz m1n1-aurora-1.6.1.aurora1-2-aarch64.pkg.tar.xz; do
    echo cached >"$R/var/cache/pacman/pkg/$file"
  done
  repo core <<<"pacman 7.0.0-1"
  printf 'hyprland 0.51-1\nlimine 12.9.0-1\nquickshell 0.3.1-1\n' | repo extra
  printf 'asahi-scripts 20260127.1-1\nasahi-alarm-keyring 20250101-1\n' | repo asahi-alarm
  printf 'dotnet-runtime 9.0.8.sdk100-1\nhyprland 0.50-1\nlimine-mkinitcpio-hook 1.36.0-3\nmise 2026.9.4-1\nobs-studio 32.2.2-1\npinta 3.1.2-2\nuboot-asahi 2026.07.asahi2-3\n' |
    repo omarchy-fork omarchy
  printf 'linux-aurora 7.1.12.aurora2-7\nlinux-aurora-headers 7.1.12.aurora2-7\nm1n1-aurora 1.6.1.aurora1-2\n' | repo omarchy-aurora
  sign_repo omarchy-fork omarchy
  sign_repo omarchy-aurora omarchy-aurora
  repo omarchy <<EDGE
omarchy 4.0.4-1
omarchy-settings 4.0.4-1
omarchy-dev $official_dev
omarchy-settings-dev $official_dev
omarchy-mac 0.1.0-6
omarchy-mac-boot 20260927-1
omarchy-keyring 20251027-1
linux-aurora 7.1.12.aurora2-10
linux-aurora-headers 7.1.12.aurora2-10
m1n1-aurora 1.6.1.aurora1-3
uboot-asahi 2026.07.asahi2-4
limine-mkinitcpio-hook 1.39.0-2
dotnet-runtime-bin 10.0.401-2
mise-bin 2026.9.12-1
omarchy-nvim 2026.9.21-1
pinta 3.1.2-1
ttf-jetbrains-mono-nerd-basic 3.5.1-1
EDGE
  alarm_repos
  for name in core extra asahi-alarm; do
    cp "$F/repos/$name/$name.db" "$R/var/lib/pacman/sync/"
  done
  fork_update
  printf 'mise-bin mise\ndotnet-runtime-bin dotnet-runtime-10.0\n' >"$F/provides"
  cat >"$F/conflicts" <<'CONFLICTS'
omarchy omarchy-dev
omarchy-settings omarchy-settings-dev
quickshell quickshell-git
mise-bin mise
linux-aurora linux-asahi
m1n1-aurora m1n1
linux-aurora-headers linux-asahi-headers
CONFLICTS

  cp -r "$tmp/mx-set" "$F/set"
  cat >"$R/etc/omarchy-mac/migration-target" <<TARGET
format=1
type=candidate-set
channel=edge
server=file://$F/repos/omarchy
set=$F/set
fingerprint=$signer
TARGET
  echo edge >"$F/channel"
  echo apple-silicon >"$F/platform"
  echo "base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck" >"$F/hooks"
  printf '%s\n' "$R/boot/efi" >"$F/mounts"
  echo /dev/mapper/root >"$F/root-source"
  printf '/dev/mapper/root crypt btrfs\n/dev/nvme0n1p6 part crypto_LUKS\n/dev/nvme0n1 disk \n' >"$F/lsblk"
  : >"$F/pacman.log"
  : >"$F/boot.log"
}

# The archives preflight reads from a repository target: both runtimes and
# omarchy-mac-boot, at the versions [omarchy] lists.
repository_archives() {
  archive omarchy-dev "$official_dev"
  archive omarchy 4.0.4-1
  archive omarchy-mac-boot 20260927-1
}

# repository_target CHANNEL: the official [omarchy] as the administrator's
# repository target for CHANNEL.
repository_target() {
  printf 'format=1\ntype=repository\nchannel=%s\nserver=file://%s/repos/omarchy\n' "$1" "$F" >"$R/etc/omarchy-mac/migration-target"
  repository_archives
}

# Everything a finished migration leaves that must not depend on how it got
# there: packages, configuration, databases, keys, loader, records and backups.
outcome() {
  local state
  state=$(state_dir)
  cat "$R/var/lib/pacman/local/packages"
  sed "s|$F|FIXTURE|g" "$R/etc/pacman.conf"
  sort "$R/etc/pacman.d/gnupg/keys"
  cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI" "$R/etc/default/limine" "$R/etc/crypttab" "$R/boot/efi/limine.conf"
  ls "$R/var/lib/omarchy"
  ls "$R/var/lib/pacman/sync"
  cat "$R/var/lib/pacman/sync/omarchy.db"
  [[ ! -e $R/var/lib/pacman/db.lck ]] && echo unlocked
  sed -n 's/^target=//p' "$state/complete"
  (cd "$state/backup" && find . -type f | LC_ALL=C sort && sed 's/^[0-9a-f]* //' SHA256SUMS)
  ls "$state"
  [[ ! -e $R/etc/systemd/system/omarchy-mac-migrate-verify.service ]] && echo "no unit"
}

# --- The whole transition --------------------------------------------------

new_fixture baseline
crypt_before=$(cat "$R/etc/crypttab" "$R/boot/efi/limine.conf")
digest=$(fixture_digest)
output=$(migrate check 2>&1) || fail "check passes on an mx-mac Mac ready to migrate" "$output"
grep -q "Ready: run moves this Mac (mx-mac, limine boot, encrypted) onto candidate-set apple-test-fixture .* (edge)" <<<"$output" ||
  fail "check plans the Mac with the mx-mac adapter" "$output"
[[ $(fixture_digest) == "$digest" && ! -e $(state_dir)/journal ]] || fail "check changes nothing"
output=$(migrate run 2>&1) || fail "an mx-mac Mac migrates to its reboot" "$output"
grep -q "Reboot to finish the migration to candidate-set apple-test-fixture" <<<"$output" || fail "the run asks for a reboot" "$output"
state=$(state_dir)
[[ $(cat "$state/plan/cohort") == "mx-mac" ]] || fail "the Mac is planned as mx-mac" "$(cat "$state/plan/cohort")"
grep -q "^ExecStart=/var/lib/omarchy-mac/migration/tool/omarchy-mac-migrate verify$" "$R/etc/systemd/system/omarchy-mac-migrate-verify.service" &&
  cmp -s "$tool" "$state/tool/omarchy-mac-migrate" || fail "the post-reboot unit runs the tool's own kept copy"
pass "an mx-mac Mac is planned by its own adapter and migrated up to its reboot"

expected_packages="asahi-alarm-keyring 20250101-1
dotnet-runtime-bin 10.0.401-2
hyprland 0.51-1
limine 12.9.0-1
limine-mkinitcpio-hook 1.39.0-2
linux-aurora 7.1.12.aurora2-11
linux-aurora-headers 7.1.12.aurora2-11
m1n1-aurora 1.6.1.aurora1-3
mise-bin 2026.9.12-1
obs-studio 32.2.2-1
omarchy-dev 4.0.0.r7000.gabc-1.1
omarchy-keyring 20251027-1
omarchy-mac 0.1.0-11.1
omarchy-mac-boot 20261004-1.1
omarchy-nvim 2026.9.21-1
omarchy-settings-dev 4.0.0.r7000.gabc-1.1
pacman 7.0.0-1
pinta 3.1.2-1.1
quickshell 0.3.1-1
ttf-jetbrains-mono-nerd-basic 3.5.1-1
uboot-asahi 2026.07.asahi2-4"
[[ $(cat "$R/var/lib/pacman/local/packages") == "$expected_packages" ]] ||
  fail "one transaction moves the dev pair and the bundle to official builds and Aurora to the target" "$(diff <(echo "$expected_packages") "$R/var/lib/pacman/local/packages")"
grep -qx "transaction omarchy-mac-candidate/omarchy-dev omarchy-mac-candidate/omarchy-settings-dev omarchy-mac-candidate/omarchy-mac omarchy-mac-candidate/omarchy-mac-boot omarchy-mac-candidate/linux-aurora omarchy-mac-candidate/linux-aurora-headers omarchy-mac-candidate/m1n1-aurora omarchy-mac-candidate/uboot-asahi omarchy-mac-candidate/limine-mkinitcpio-hook omarchy-mac-candidate/pinta dotnet-runtime-bin hyprland mise-bin omarchy-keyring omarchy-nvim quickshell ttf-jetbrains-mono-nerd-basic asahi-alarm-keyring" "$F/pacman.log" ||
  fail "the target's packages come from the target, and each other fork build an official repository carries is named" "$(grep transaction "$F/pacman.log")"
[[ $(grep -c '^transaction ' "$F/pacman.log") == 1 ]] || fail "one package transaction"
[[ $(cat "$state/plan/allowed-removals") == $'dotnet-runtime\nmise\nquickshell-git' &&
  $(cat "$state/plan/removals") == "$(cat "$state/plan/allowed-removals")" ]] ||
  fail "only the fork builds official ones of another name replace may be removed, and each is removed by name if it survives" "$(cat "$state/plan/allowed-removals" "$state/plan/removals")"
grep -qx "remove dotnet-runtime" "$F/pacman.log" || fail "a fork build its counterpart does not conflict with is removed by name" "$(cat "$F/pacman.log")"
grep -qx "obs-studio 32.2.2-1" "$state/plan/kept" || fail "a fork build with no official one is kept and listed" "$(cat "$state/plan/kept")"
! grep -q "^avd-fw " "$R/var/lib/pacman/local/packages" || fail "a target package the Mac never had is not installed"
pass "one transaction replaces the fork's bundle, downgrades a higher fork build, keeps what has no official build and adds no package the Mac lacks"

# omarchy-dev 4.0.4.r7081 (the fork's) sorts above the target's 4.0.0.r7000: the
# pair is named in the candidate repository and downgraded in place, never
# removed and reinstalled.
! grep -q "^omarchy-dev$\|^omarchy-settings-dev$" "$state/plan/allowed-removals" "$state/plan/removals" ||
  fail "the fork's dev pair is never planned for removal on edge"
! grep -q "^remove .*omarchy-dev\|^remove .*omarchy-settings-dev" "$F/pacman.log" && [[ ! -e $state/overwrite ]] ||
  fail "the dev pair changes in the transaction, with no removal after it and no overwrite" "$(cat "$F/pacman.log")"
pass "on edge the fork's higher omarchy-dev pair is downgraded by name to the target's in the one transaction"

conf=$(sed "s|$F|FIXTURE|g" "$R/etc/pacman.conf")
expected_conf=$(OMARCHY_MAC_MIGRATE_ROOT=$R fixture=1 bash -c 'source <(sed -n "/^core_pacman_conf() {/,/^}/p" "$1"); core_pacman_conf "file://FIXTURE/repos/omarchy"' _ "$ROOT/migrate/src/target.sh" |
  sed "s|^Server = https://github.com/asahi-alarm.*|Server = file://FIXTURE/repos/asahi-alarm|")
[[ $conf == "$expected_conf" ]] || fail "pacman.conf is the core Apple Silicon configuration, without either fork section" "$(diff <(echo "$expected_conf") <(echo "$conf"))"
[[ ! -e $R/var/lib/pacman/sync/omarchy-aurora.db && ! -e $R/var/lib/pacman/sync/omarchy-aurora.db.sig ]] || fail "the fork's Aurora database is gone"
[[ ! -e $R/var/lib/pacman/sync/omarchy.db.sig ]] && cmp -s "$F/repos/omarchy/omarchy.db" "$R/var/lib/pacman/sync/omarchy.db" ||
  fail "the official [omarchy] database replaces the fork's, without the fork's signature beside it"
! grep -q "^$fork_key \|^$release_key " "$R/etc/pacman.d/gnupg/keys" || fail "the fork's package and release keys are deleted" "$(cat "$R/etc/pacman.d/gnupg/keys")"
grep -q "^$official f" "$R/etc/pacman.d/gnupg/keys" && ! grep -q "$signer" "$R/etc/pacman.d/gnupg/keys" ||
  fail "the Omarchy key stays trusted and the candidate key never enters pacman's keyring"
pass "no fork repository, signature or key is left, and the official database is the one pacman reads"

! grep -q "update-grub" "$F/boot.log" || fail "a Limine Mac does not touch GRUB" "$(cat "$F/boot.log")"
[[ $(grep -E '^(update-m1n1|omarchy-mac-limine-cmdline|limine-update|dispatch setup-boot|limine-boot activate|dispatch setup-system|dispatch update-verify)' "$F/boot.log" | tr '\n' '|') == \
  "update-m1n1 |omarchy-mac-limine-cmdline |limine-update|dispatch setup-boot|limine-boot activate|limine-update|dispatch setup-system|dispatch update-verify|" ]] ||
  fail "m1n1 and the UKI are rebuilt, then the new setup-boot refreshes Limine, setup-system and update-verify run" "$(cat "$F/boot.log")"
[[ $(cat "$R/etc/crypttab" "$R/boot/efi/limine.conf") == "$crypt_before" && -e $R/var/lib/omarchy/limine.enabled ]] ||
  fail "the unlock settings and the Limine menu are unchanged"
grep -q "^cryptsetup luksHeaderBackup /dev/nvme0n1p6 " "$F/pacman.log" && [[ -f $state/backup/luks-header.img ]] ||
  fail "the LUKS header of the root partition is backed up"
tar -xOf "$state/backup/etc.tar" etc/pacman.conf | grep -q '^\[omarchy-aurora\]' || fail "the backup holds the fork's pacman.conf"
pass "encryption and Limine are kept: the UKI is rebuilt, setup-boot refreshes Limine, the LUKS header is backed up"

reboot_into_aurora
output=$(migrate verify 2>&1) || fail "the post-reboot verification completes the migration" "$output"
grep -q "Kept, with no official build: obs-studio" <<<"$output" || fail "completion names what was kept" "$output"
for name in asahi-quattro-release asahi-quattro-release.pending asahi-package-repository aurora-target.descriptor apple-silicon-channel apple-silicon-aurora-lane; do
  [[ ! -e $R/var/lib/omarchy/$name && -f $state/backup/mx-mac-state/$name ]] || fail "the fork updaters' $name is moved into the backup"
done
[[ $(stat -c %a "$state/backup/mx-mac-state") == 700 ]] || fail "the retired state is readable by root only"
[[ -e $R/var/lib/omarchy/mac-first-boot/install.conf ]] || fail "state no fork updater owns stays"
[[ ! -e $R/etc/systemd/system/omarchy-mac-migrate-verify.service && ! -e $state/tool ]] || fail "the post-reboot unit and the tool's copy go"
[[ $(migrate status) == *"State: complete"* ]] || fail "status reports completion"
baseline=$(outcome)
pass "after the reboot, the bundle and channel updaters' state is retired into the backup"

output=$(migrate run 2>&1) || fail "a second run succeeds" "$output"
grep -q "Already migrated to candidate-set apple-test-fixture" <<<"$output" && [[ $(outcome) == "$baseline" ]] ||
  fail "a second run changes nothing" "$output"
pass "the migration is idempotent"

# --- Interruption at every journal step ---------------------------------------

interrupt() { # when step
  local when=$1 step=$2 status=0 output last recorded transactions=1
  new_fixture "kill-$when-$step"
  output=$(migrate_env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$step" -- run 2>&1) || status=$?
  if (( status == 0 )); then
    reboot_into_aurora
    output=$(migrate_env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$step" -- verify 2>&1) || status=$?
  fi
  (( status == 137 )) || fail "the run is killed $when $step" "status $status: $output"
  case $step in
    loader-leaf) recorded=loader ;;
    removals) recorded=transaction ;;
    mx-mac-retire) recorded=retire ;;
    *) recorded=$step ;;
  esac
  last=$(tail -n 1 "$(state_dir)/journal" | cut -d' ' -f2-)
  if [[ $when == "after" ]]; then
    [[ $last == "$recorded done"* ]] || fail "the journal ends with $step done" "$last"
  else
    [[ $last == "$recorded begin"* ]] || fail "the journal ends with $step begun" "$last"
  fi
  finish
  [[ $(outcome) == "$baseline" ]] || fail "killed $when $step, the resumed migration ends where an uninterrupted one does" "$(diff <(echo "$baseline") <(outcome))"
  [[ $when$step == "midtransaction" ]] && transactions=2
  [[ $(grep -c '^transaction ' "$F/pacman.log") == "$transactions" ]] || fail "killed $when $step: $transactions package transaction(s)" "$(cat "$F/pacman.log")"
  [[ $(grep '^transaction \|^hooks' "$F/pacman.log" | tail -n 1) == "hooks" ]] || fail "killed $when $step: the last transaction's hooks ran"
  [[ $(grep -c '^remove dotnet-runtime$' "$F/pacman.log") == 1 ]] || fail "killed $when $step: the planned removal runs once" "$(cat "$F/pacman.log")"
}

for step in "${steps[@]}"; do
  interrupt after "$step"
done
pass "a kill -9 between any two journal steps resumes to the same end, with one transaction"
for step in "${steps[@]}"; do
  interrupt during "$step"
done
pass "a kill -9 after any step's work but before its record resumes to the same end"
for step in backup keyring prefetch repositories transaction removals boot-chain loader loader-leaf defaults unpin reboot mx-mac-retire retire; do
  interrupt mid "$step"
done
pass "a kill -9 in the middle of any step, the removals after the transaction and the adapter's retire included, resumes to the same end"

# --- The fork moving under a migration -----------------------------------------

# The fork's omarchy update runs before the migration resumes: its channel
# updaters put the fork sections, databases and key back, and its bundle
# updater moves the runtime pair.
for step in keyring repositories; do
  new_fixture "fork-update-$step"
  kill_after "$step"
  fork_update
  sed -i 's/^omarchy-dev .*/omarchy-dev 4.0.4.r7090.g0123456-1/' "$R/var/lib/pacman/local/packages"
  finish
  [[ $(outcome) == "$baseline" ]] || fail "after the fork's update past $step, the migration ends where an uninterrupted one does" "$(diff <(echo "$baseline") <(outcome))"
  [[ $(grep -c '^transaction ' "$F/pacman.log") == 1 ]] || fail "after $step: one transaction"
  [[ $step != "repositories" ]] || grep -q " prefetch reset pacman.conf or a retired key came back after the repository switch" "$(state_dir)/journal" ||
    fail "the fork's update after the switch sends the migration back to rehearse" "$(cat "$(state_dir)/journal")"
done
pass "the fork's own update between steps is undone: the switch runs again and no fork section survives"

new_fixture conf-only
kill_after repositories
fork_pacman_conf >"$R/etc/pacman.conf"
finish
grep -q " prefetch reset pacman.conf or a retired key came back after the repository switch" "$(state_dir)/journal" || fail "a rewritten pacman.conf alone is noticed" "$(cat "$(state_dir)/journal")"
[[ $(outcome) == "$baseline" ]] || fail "a rewritten pacman.conf is switched again" "$(diff <(echo "$baseline") <(outcome))"
pass "a channel updater's rewrite of pacman.conf after the switch is switched back before the transaction"

new_fixture key-only
kill_after repositories
echo "$release_key f" >>"$R/etc/pacman.d/gnupg/keys"
finish
grep -q " prefetch reset pacman.conf or a retired key came back after the repository switch" "$(state_dir)/journal" ||
  fail "a fork key trusted again alone is noticed" "$(cat "$(state_dir)/journal")"
[[ $(outcome) == "$baseline" ]] || fail "a fork key trusted again is deleted again" "$(diff <(echo "$baseline") <(outcome))"
pass "a fork key trusted again after the switch is deleted again before the transaction"

# --- The channel ------------------------------------------------------------------

# Without an administrator's target, an mx-mac Mac follows the channel the fork
# records (omarchy-apple-silicon-channel current), served from Omarchy's
# official repository for that channel.
channel_fixture() { # name channel
  new_fixture "$1"
  rm "$R/etc/omarchy-mac/migration-target"
  echo "$2" >"$F/channel"
}

for channel in rc stable; do
  channel_fixture "channel-$channel" "$channel"
  # Omarchy's rc and stable today: the runtime, no Mac packages.
  printf 'omarchy 4.0.4-1\nomarchy-settings 4.0.4-1\nomarchy-keyring 20251027-1\n' | repo "official-$channel" omarchy
  refused "an mx-mac Mac on $channel" "the $channel channel has no omarchy-mac for Apple Silicon yet"
  output=$(migrate run 2>&1 || true)
  grep -q "The $channel channel has no Mac release yet" <<<"$output" || fail "the $channel deferral says why" "$output"
  [[ $(migrate status) == *"The last run deferred: "*"$channel channel has no omarchy-mac"* ]] || fail "status says why $channel deferred" "$(migrate status)"
done
pass "an mx-mac Mac on rc or stable defers with nothing changed while its channel has no Mac packages"

channel_fixture channel-held held
refused "a held channel" "cannot tell which Omarchy channel this Mac follows"
channel_fixture channel-none edge
rm "$F/channel"
refused "no channel record" "cannot tell which Omarchy channel this Mac follows"
pass "an mx-mac Mac whose channel the fork cannot name defers with nothing changed"

channel_fixture channel-edge edge
cp -r "$F/repos/omarchy" "$F/repos/official-edge"
repository_archives
output=$(migrate check 2>&1) || fail "an mx-mac Mac on edge is ready" "$output"
grep -q "Ready: run moves this Mac (mx-mac, limine boot, encrypted) onto repository file://$F/repos/official-edge (edge)" <<<"$output" ||
  fail "the fork's edge channel moves to Omarchy's edge repository" "$output"
finish
grep -qx "transaction omarchy/omarchy-dev omarchy/omarchy-settings-dev omarchy/omarchy-mac omarchy/omarchy-mac-boot omarchy/linux-aurora omarchy/linux-aurora-headers omarchy/m1n1-aurora omarchy/uboot-asahi omarchy/limine-mkinitcpio-hook dotnet-runtime-bin hyprland mise-bin omarchy-keyring omarchy-nvim pinta quickshell ttf-jetbrains-mono-nerd-basic asahi-alarm-keyring" "$F/pacman.log" ||
  fail "every Mac package and the dev pair are named in the official [omarchy]" "$(grep transaction "$F/pacman.log")"
[[ $(grep -c '^transaction ' "$F/pacman.log") == 1 ]] || fail "one package transaction"
grep -qx "omarchy-dev $official_dev" "$R/var/lib/pacman/local/packages" && grep -qx "omarchy-settings-dev $official_dev" "$R/var/lib/pacman/local/packages" &&
  grep -qx "omarchy-mac-boot 20260927-1" "$R/var/lib/pacman/local/packages" ||
  fail "Omarchy's own dev pair replaces the fork's higher one" "$(cat "$R/var/lib/pacman/local/packages")"
! grep -q "^remove .*omarchy-dev" "$F/pacman.log" && ! grep -q "omarchy-dev" "$(state_dir)/plan/allowed-removals" ||
  fail "the dev pair is downgraded inside the transaction, never removed" "$(cat "$F/pacman.log")"
grep -q "^download omarchy-dev $official_dev$" "$F/pacman.log" && grep -q "^download omarchy-mac-boot 20260927-1$" "$F/pacman.log" ||
  fail "preflight reads the channel's signed runtime and boot archives" "$(cat "$F/pacman.log")"
grep -qx "Server = file://$F/repos/official-edge" "$R/etc/pacman.conf" || fail "[omarchy] is Omarchy's edge repository" "$(cat "$R/etc/pacman.conf")"
pass "with no administrator's target, an mx-mac Mac on edge moves to Omarchy's own dev pair, downgraded by name in one transaction"

# --- Repository targets ------------------------------------------------------------

# On stable the fork's pair gives way to omarchy and omarchy-settings, whose
# conflicts remove it in the transaction.
new_fixture repository-stable
repository_target stable
finish
grep -qx "transaction omarchy/omarchy omarchy/omarchy-settings omarchy/omarchy-mac omarchy/omarchy-mac-boot omarchy/linux-aurora omarchy/linux-aurora-headers omarchy/m1n1-aurora omarchy/uboot-asahi omarchy/limine-mkinitcpio-hook dotnet-runtime-bin hyprland mise-bin omarchy-keyring omarchy-nvim pinta quickshell ttf-jetbrains-mono-nerd-basic asahi-alarm-keyring" "$F/pacman.log" ||
  fail "a stable repository target names the Mac packages in the official [omarchy], not the fork's" "$(grep transaction "$F/pacman.log")"
grep -qx "omarchy 4.0.4-1" "$R/var/lib/pacman/local/packages" && ! grep -q "^omarchy-dev \|^omarchy-settings-dev " "$R/var/lib/pacman/local/packages" ||
  fail "the official runtime replaces the fork's dev pair" "$(cat "$R/var/lib/pacman/local/packages")"
[[ $(cat "$(state_dir)/plan/allowed-removals") == $'dotnet-runtime\nmise\nomarchy-dev\nomarchy-settings-dev\nquickshell-git' ]] ||
  fail "on stable the fork's pair may be removed" "$(cat "$(state_dir)/plan/allowed-removals")"
! grep -q "^remove .*omarchy-dev" "$F/pacman.log" || fail "the fork's pair leaves through omarchy's conflict" "$(cat "$F/pacman.log")"
pass "a stable repository target, whose [omarchy] has the fork section's name, replaces the fork's builds"

# omacom's own omarchy-dev provides omarchy: once it is newer than the fork's,
# an upgrade would take it and pacman would drop the omarchy target.
new_fixture newer-official-dev
repository_target stable
sed -i 's/^omarchy-dev .*/omarchy-dev 4.0.5.r1-1/' "$F/repos/omarchy/omarchy.db"
printf 'omarchy-dev omarchy\n' >>"$F/provides"
finish
grep -qx "omarchy 4.0.4-1" "$R/var/lib/pacman/local/packages" && ! grep -q "^omarchy-dev " "$R/var/lib/pacman/local/packages" ||
  fail "the runtime pair still comes from the target when an official omarchy-dev is newer than the fork's" "$(cat "$R/var/lib/pacman/local/packages")"
pass "the planned removals stay out of the upgrade, so a newer official omarchy-dev cannot displace the omarchy target"

# --- Commands that change hands --------------------------------------------------

# A real mx-mac Mac has no omarchy-mac-boot: its omarchy-dev owns five of the
# commands omarchy-mac-boot ships. The one transaction installs omarchy-mac-boot
# while the fork's omarchy-dev is replaced (on edge, by Omarchy's own, which
# ships none of them; on stable, through omarchy's conflict), so the commands
# change hands with nothing overwritten.
handover="/usr/bin/omarchy-apple-silicon-boot-check /usr/bin/omarchy-mac-boot-update /usr/bin/omarchy-mac-limine-active /usr/bin/omarchy-mac-limine-cmdline /usr/bin/omarchy-mac-limine-deploy"

handover_fixture() {
  local path
  new_fixture "$1"
  mkdir -p "$F/files" "$R/usr/bin"
  : >"$R/var/lib/pacman/local/files"
  for path in $handover; do
    printf '%s\n' "$path" >>"$F/files/omarchy-mac-boot"
    printf 'omarchy-dev %s\n' "$path" >>"$R/var/lib/pacman/local/files"
    echo "omarchy-dev $fork_dev" >"$R$path"
  done
}

handed_over() { # version
  local path
  for path in $handover; do
    [[ $(cat "$R$path") == "omarchy-mac-boot $1" ]] && grep -qx "omarchy-mac-boot $path" "$R/var/lib/pacman/local/files" &&
      ! grep -qx "omarchy-dev $path" "$R/var/lib/pacman/local/files" ||
      fail "$path moves from the fork's omarchy-dev to omarchy-mac-boot" "$(grep -F "$path" "$R/var/lib/pacman/local/files")"
  done
  [[ ! -e $(state_dir)/overwrite ]] && ! grep -q "^remove .*omarchy-dev" "$F/pacman.log" ||
    fail "omarchy-dev changes inside the transaction, with nothing overwritten" "$(cat "$F/pacman.log")"
}

handover_fixture handover-edge
finish
handed_over 20261004-1.1
grep -qx "omarchy-dev 4.0.0.r7000.gabc-1.1" "$R/var/lib/pacman/local/packages" || fail "the fork's omarchy-dev is downgraded in place"
handover_fixture handover-stable
repository_target stable
finish
handed_over 20260927-1
pass "the commands the fork's omarchy-dev owned pass to omarchy-mac-boot inside the one transaction, without an overwrite"

# Without omarchy's conflict, omarchy-dev would leave in the removals after the
# transaction, and pacman -R would delete the commands omarchy-mac-boot took over.
handover_fixture after-removal
repository_target stable
sed -i '/^omarchy omarchy-dev$/d' "$F/conflicts"
conf_before=$(cat "$R/etc/pacman.conf")
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 75 )) && grep -q "would leave omarchy-dev to be removed after it, but the packages it installs also own /usr/bin/omarchy-apple-silicon-boot-check" <<<"$output" ||
  fail "a removal that would take handed-over files stops the rehearsal, deferred" "status $status: $output"
[[ $(cat "$R/etc/pacman.conf") == "$conf_before" ]] && grep -q "^omarchy-dev " "$R/var/lib/pacman/local/packages" &&
  ! grep -q "^transaction \|^remove " "$F/pacman.log" || fail "nothing changes before such a transaction" "$(cat "$F/pacman.log")"
[[ ! -e $(state_dir)/journal ]] || fail "the attempt is set aside, so the next run starts over"
pass "a planned removal that shares files with the packages installed defers before anything changes"

# --- Refusals and failures -------------------------------------------------------

new_fixture refusals
printf '\n[custom]\nSigLevel = Optional TrustAll\nServer = file:///custom\n' >>"$R/etc/pacman.conf"
refused "an unknown TrustAll repository" "\[custom\] accepts untrusted packages"
new_fixture refusals
echo "base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems fsck" >"$F/hooks"
refused "busybox encrypt" "busybox encrypt"
new_fixture refusals
: >"$R/var/lib/omarchy/mac-first-boot/pending"
refused "an unfinished first boot" "first boot has not finished"
new_fixture refusals
rm "$F/hooks"
refused "HOOKS that cannot be read" "cannot read the initramfs HOOKS"
new_fixture refusals
head -c 16 /dev/urandom >>"$F/set/$(jq -r '.packages[0].filename' "$F/set/manifest.json")"
refused "a tampered candidate package" "does not verify: omarchy-dev-.* is missing or changed"
new_fixture refusals
repository_target stable
sed -i '/^omarchy-mac /d' "$F/repos/omarchy/omarchy.db"
refused "a target without omarchy-mac" "the stable channel has no omarchy-mac for Apple Silicon yet"
new_fixture refusals
repository_target stable
printf 'packages=omarchy omarchy-mac omarchy-mac-boot linux-aurora\n' >>"$R/etc/omarchy-mac/migration-target"
refused "a target without the runtime pair" "the target has no omarchy-settings to replace the fork's runtime pair"
pass "preflight refuses legacy unlock, untrusted repositories, an unfinished first boot, unreadable HOOKS and an incomplete or unverifiable target, changing nothing"

new_fixture weak-fork
sed -i '/^\[omarchy-aurora\]/,/^$/s/^SigLevel = .*/SigLevel = Optional TrustAll/' "$R/etc/pacman.conf"
finish
[[ $(outcome) == "$baseline" ]] || fail "a fork section the switch drops is not a refusal, whatever its SigLevel" "$(diff <(echo "$baseline") <(outcome))"
pass "the fork's own sections are retired, not refused"

new_fixture removal
echo "omarchy-mac obs-studio" >>"$F/conflicts"
conf_before=$(cat "$R/etc/pacman.conf")
packages_before=$(cat "$R/var/lib/pacman/local/packages")
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 75 )) && grep -q "would also remove obs-studio; nothing was changed" <<<"$output" || fail "an unexpected removal stops the rehearsal, deferred" "status $status: $output"
[[ $(cat "$R/etc/pacman.conf") == "$conf_before" && $(cat "$R/var/lib/pacman/local/packages") == "$packages_before" ]] ||
  fail "the fork's repositories and packages are untouched after a failed rehearsal"
[[ ! -e $(state_dir)/journal && -n $(ls -d "$(state_dir)"/history/aborted-* 2>/dev/null) ]] || fail "the attempt is set aside, so the next run starts over"
pass "a rehearsal that would remove a kept fork build defers before the switch"

new_fixture after-boundary
kill_after repositories
: >"$F/fail-transaction"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && [[ -f $(state_dir)/journal ]] || fail "a failure after the switch is a failure, never a deferral" "status $status: $output"
rm "$F/fail-transaction"
finish
[[ $(outcome) == "$baseline" ]] || fail "the resumed migration ends where an uninterrupted one does" "$(diff <(echo "$baseline") <(outcome))"
pass "after the repository switch a failure stops the migration for the next run to resume"

# --- Other mx-mac Macs -------------------------------------------------------------

# Omarchy's edge carries quickshell-git itself: a fork build moves to the
# official build of its own name before a renamed one.
new_fixture same-name
printf 'quickshell-git 0.3.0.r20.g28771c7-3\n' >>"$F/repos/omarchy/omarchy.db"
finish
grep -qx "quickshell-git 0.3.0.r20.g28771c7-3" "$R/var/lib/pacman/local/packages" && ! grep -q "^quickshell " "$R/var/lib/pacman/local/packages" ||
  fail "a fork build an official repository carries by its own name moves to that build" "$(cat "$R/var/lib/pacman/local/packages")"
! grep -qx "quickshell-git" "$(state_dir)/plan/allowed-removals" && grep -q "^transaction .* quickshell-git ttf-jetbrains-mono-nerd-basic asahi-alarm-keyring$" "$F/pacman.log" ||
  fail "the official build of the same name is named and nothing is removed for it" "$(cat "$(state_dir)/plan/allowed-removals" "$F/pacman.log")"
pass "a fork build moves to the official build of its own name before a renamed counterpart"

new_fixture grub
rm "$R/var/lib/omarchy/limine.enabled" "$R/etc/default/limine" "$R/boot/efi/limine.conf" "$R/boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
echo grub >"$R/boot/efi/EFI/BOOT/BOOTAA64.EFI"
finish
grep -q "^update-grub" "$F/boot.log" && grep -q "^limine-boot activate" "$F/boot.log" &&
  [[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" && -e $R/var/lib/omarchy/limine.enabled ]] ||
  fail "an mx-mac Mac on GRUB is switched to Limine" "$(cat "$F/boot.log")"
[[ $(cat "$(state_dir)/plan/boot") == "grub" ]] || fail "the Mac is planned as a GRUB Mac"
pass "an mx-mac Mac that still boots GRUB is switched to Limine"

# --- Omarchy's own dev channel ------------------------------------------------------

# omacom's omarchy-dev on a Mac that never ran the fork.
official_dev_fixture() {
  new_fixture "$1"
  rm -f "$R"/var/lib/omarchy/asahi-* "$R/var/lib/omarchy/aurora-target.descriptor" "$R"/var/lib/omarchy/apple-silicon-* \
    "$R/etc/omarchy-mac/migration-target" "$R"/var/lib/pacman/sync/omarchy-aurora.db* "$R/var/lib/pacman/sync/omarchy.db.sig"
  cat >"$R/etc/pacman.conf" <<CONF
[options]
Architecture = aarch64
SigLevel = Required DatabaseOptional

[omarchy]
Server = https://pkgs.omarchy.org/edge/\$arch

[core]
Include = /etc/pacman.d/mirrorlist
CONF
  sed -i "/^$fork_key /d; /^$release_key /d" "$R/etc/pacman.d/gnupg/keys"
}

official_dev_fixture official-dev
digest=$(fixture_digest)
output=$(migrate run 2>&1) || fail "a Mac on Omarchy's dev channel is not refused" "$output"
grep -q "runs Omarchy's own packages (omarchy-dev from pkgs.omarchy.org): nothing to migrate" <<<"$output" &&
  [[ $(fixture_digest) == "$digest" && ! -e $(state_dir)/journal ]] ||
  fail "a Mac on Omarchy's dev channel has nothing to migrate and nothing changes" "$output"
official_dev_fixture official-dev-fork-key
echo "$fork_key f" >>"$R/etc/pacman.d/gnupg/keys"
cp -r "$F/repos/omarchy" "$F/repos/official-edge"
repository_archives
digest=$(fixture_digest)
output=$(migrate check 2>&1) || fail "omarchy-dev beside a retired key is migrated" "$output"
grep -q "Ready: run moves this Mac (tester, limine boot, encrypted) onto repository file://$F/repos/official-edge (edge)" <<<"$output" &&
  [[ $(fixture_digest) == "$digest" ]] || fail "omarchy-dev that is not the fork's, beside retired trust, is moved like a tester to its channel" "$output"
pass "omarchy-dev from Omarchy's own repositories is nothing to migrate; beside retired trust it is moved like a tester"

# --- Migrations a converted Mac records as done ----------------------------------------

new_fixture settled
printf 'root:x:0:0::/root:/bin/bash\ntester:x:1000:1000::/home/tester:/bin/bash\n' >"$R/etc/passwd"
migrations=$R/home/tester/.local/state/omarchy/migrations
mkdir -p "$migrations"
: >"$migrations/1790305681.sh"
printf '2026-09-20T10:00:00+10:00\thandled\tHyprland configuration replaced by the Quattro user transition\n' >"$migrations/1781063758.sh.skipped"
printf '2026-09-20T10:00:00+10:00\tskipped\tunsupported AUR browser replacement on Asahi\n' >"$migrations/1784510887.sh.skipped"
printf '2026-09-20T10:00:00+10:00\tskipped\tsystemd-oomd reclaim tuning is held until validated on Asahi\n' >"$migrations/1785424256.sh.skipped"
printf '2026-09-20T10:00:00+10:00\thandled\tnot one the adapter audited\n' >"$migrations/1786567036.sh.skipped"
finish
for name in 1781063758 1784476564 1785424256 1786391100 1789444024 1789158179 1789172112 1790327324; do
  [[ -f $migrations/$name.sh ]] || fail "$name is recorded as done" "$(ls "$migrations")"
done
for name in 1784510887 1786567036; do
  [[ ! -e $migrations/$name.sh ]] || fail "$name is left to run on the new packages"
done
grep -qx 'omarchy-mac-setup-keyboard 3' "$F/boot.log" || fail "mx-mac's keyboard migration names the generated keyboard line" "$(grep keyboard "$F/boot.log")"
grep -q "^dispatch setup-user HOME=$R/home/tester$" "$F/boot.log" || fail "the Mac user setup runs for the fork's user" "$(grep setup-user "$F/boot.log")"
pass "a converted Mac records the fork's handled migrations and those a fresh Mac image never runs as done, and leaves the rest to run"
