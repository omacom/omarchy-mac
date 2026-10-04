#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/test/fixtures/mac-migrate/lib.sh"

# bin/omarchy-mac-migrate moves a legacy omarchy-mac Mac (the quattro fork)
# onto Omarchy's official edge: the omarchy-dev pair, the Mac packages and the
# Aurora chain. Legacy fixtures turn on the stand-in pacman's file ownership,
# signature trust and removal dependencies: a transaction refuses to write over
# a file it does not own, and a package from a repository that requires
# signatures must be signed by a key the keyring trusts.

fork=FBD6874D423C418DDB6D143EECE19CDDE306DBD2
alarm=1111111111111111111111111111111111111111
asahi=2222222222222222222222222222222222222222
checkout=/home/owner/.local/share/omarchy
# omarchy-mac-boot's HOOKS resolver, its Limine command line and its
# mkinitcpio drop-ins, as omacom/omarchy-mac-pkgs 4399105 ships them.
mac_boot=$ROOT/test/fixtures/mac-migrate/mac-boot

# ships PACKAGE PATH...: the files a package installs.
ships() {
  local name=$1
  shift
  printf '%s\n' "$@" >"$F/files/$name"
}

# owns PACKAGE PATH...: installed files and their owner.
owns() {
  local name=$1 path
  shift
  for path; do
    mkdir -p "$(dirname "$R$path")"
    echo "$name" >"$R$path"
    echo "$name $path" >>"$R/var/lib/pacman/local/files"
  done
}

# unowned CONTENT PATH...: files the checkout's setup wrote.
unowned() {
  local content=$1 path
  shift
  for path; do
    mkdir -p "$(dirname "$R$path")"
    echo "$content" >"$R$path"
  done
}

# A legacy Mac on the Asahi kernel and GRUB, unencrypted, with the fork's
# repository, keyring and busybox HOOKS line; the signed candidate set as the
# administrator's target, with the edge repository for everything else. LAYOUT
# is checkout (a 3.x checkout upgraded to Quattro: no omarchy package, the
# checkout wired into /usr) or channel (the pair from an rc lane, a dev link to
# a checkout).
new_fixture() {
  local name=$1 layout=$2 link
  F=$tmp/$name
  R=$F/root
  rm -rf "$F"
  mkdir -p "$R" "$F/files"
  mkdir -p "$R/run/systemd/system" "$R/run/lock" "$R/var/tmp" "$R/proc/sys/kernel/random" "$R/etc/default" "$R/etc/omarchy-mac" \
    "$R/var/lib/pacman/local" "$R/var/lib/pacman/sync" "$R/var/cache/pacman/pkg" "$R/etc/pacman.d/gnupg" \
    "$R/usr/share/pacman/keyrings" "$R/usr/share/limine" "$R/boot/grub" "$R/boot/efi/EFI/BOOT" "$R/boot/efi/m1n1" \
    "$R/usr/lib/modules/6.19.1-asahi" "$R/usr/lib/modules/7.1.12-aurora" "$R/var/lib/omarchy" "$R/usr/bin" \
    "$R/var/cache/omarchy/channels/transaction.Stale01" "$R/etc/sudoers.d" "$R/etc/mkinitcpio.conf.d"
  echo boot-1 >"$R/proc/sys/kernel/random/boot_id"
  echo 6.19.1-asahi >"$R/proc/sys/kernel/osrelease"
  echo linux-asahi >"$R/usr/lib/modules/6.19.1-asahi/pkgbase"
  echo linux-aurora >"$R/usr/lib/modules/7.1.12-aurora/pkgbase"
  echo "menuentry linux-asahi" >"$R/boot/grub/grub.cfg"
  echo grub >"$R/boot/efi/EFI/BOOT/BOOTAA64.EFI"
  echo m1n1 >"$R/boot/efi/m1n1/boot.bin"
  echo "limine 12.9" >"$R/usr/share/limine/BOOTAA64.EFI"
  echo 'GRUB_CMDLINE_LINUX=""' >"$R/etc/default/grub"
  mkdir -p "$R/etc/sddm.conf.d"
  printf '[Autologin]\nUser=owner\nSession=omarchy.desktop\n' >"$R/etc/sddm.conf.d/autologin.conf"
  for keyring in archlinuxarm asahi-alarm; do
    : >"$R/usr/share/pacman/keyrings/$keyring.gpg"
  done
  echo "$alarm" >"$R/usr/share/pacman/keyrings/archlinuxarm-trusted"
  echo "$asahi" >"$R/usr/share/pacman/keyrings/asahi-alarm-trusted"
  printf '%s f\n%s f\n%s f\n' "$alarm" "$asahi" "$fork" >"$R/etc/pacman.d/gnupg/keys"
  mkdir -p "$F/keyserver"
  : >"$F/keyserver/$official"
  : >"$R/var/lib/pacman/local/files"

  # The checkout, never written by the migration.
  mkdir -p "$R$checkout/bin" "$R$checkout/.git" "$R$checkout/default/bash"
  for name in omarchy-update omarchy-hw-apple omarchy-upgrade-to-quattro-mac; do
    echo "checkout $name" >"$R$checkout/bin/$name"
  done
  echo "checkout env" >"$R$checkout/default/bash/env-bootstrap"
  echo "4.0.3" >"$R$checkout/version"

  repo core <<<"pacman 7.0.0-1 $alarm"
  printf 'hyprland 0.51-1 %s\nlimine 12.9.0-1 %s\n' "$alarm" "$alarm" | repo extra
  printf 'linux-asahi 6.19.1-1 %s\nm1n1 1.5.0-1 %s\nuboot-asahi 2026.01-1 %s\nasahi-alarm-keyring 20250101-1 %s\n' "$asahi" "$asahi" "$asahi" "$asahi" |
    repo asahi-alarm
  sed "s/\$/ $official/" <<'EDGE' | repo omarchy
omarchy 4.0.4-1
omarchy-settings 4.0.4-1
omarchy-dev 4.0.0.r6713.ga85e29a-1
omarchy-settings-dev 4.0.0.r6713.ga85e29a-1
omarchy-mac 0.1.0-6
omarchy-mac-boot 20260927-1
linux-aurora 7.1.12.aurora2-10
linux-aurora-headers 7.1.12.aurora2-10
m1n1-aurora 1.6.1.aurora1-3
uboot-asahi 2026.07.asahi2-4
limine-mkinitcpio-hook 1.39.0-2
omarchy-keyring 20260920-1
ttf-jetbrains-mono-nerd-basic 3.4.0-2
quickshell-git 0.2-1
EDGE
  sed "s/\$/ $fork/" <<'FORK' | repo omarchy-aarch64
omarchy 4.0.3rc4-1
omarchy-settings 4.0.3rc4-1
omarchy-mac-keyring 20260914-2
quickshell-git 0.1-1
voxtype 1.0-1
FORK
  cp "$F/repos/omarchy-aarch64/omarchy-aarch64.db" "$R/var/lib/pacman/sync/"
  alarm_repos
  relations
  echo "omarchy 4.0.3rc4-1 omarchy-mac-keyring omarchy-settings" >"$F/depends"
  : >"$F/verify-signatures"

  ships omarchy-dev /usr/share/omarchy/bin/omarchy-update /usr/share/omarchy/default/bash/env-bootstrap /usr/bin/omarchy-update
  ships omarchy-settings-dev /etc/sddm.conf.d/10-theme.conf /etc/profile.d/omarchy.sh /usr/share/uwsm/env.d/10-omarchy
  echo /etc/sddm.conf.d/10-theme.conf >"$F/backups"
  # The legacy detector alias belongs to omarchy-mac.
  ships omarchy-mac /usr/bin/omarchy-hw-apple
  ships omarchy-keyring /usr/share/pacman/keyrings/omarchy.gpg /usr/share/pacman/keyrings/omarchy-trusted
  ships ttf-jetbrains-mono-nerd-basic /usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf
  owns omarchy-mac-keyring /usr/share/pacman/keyrings/omarchy-mac.gpg /usr/share/pacman/keyrings/omarchy-mac-revoked
  printf '%s:4:\n' "$fork" >"$R/usr/share/pacman/keyrings/omarchy-mac-trusted"
  echo "omarchy-mac-keyring /usr/share/pacman/keyrings/omarchy-mac-trusted" >>"$R/var/lib/pacman/local/files"

  if [[ $layout == "checkout" ]]; then
    cat >"$R/var/lib/pacman/local/packages" <<'LOCAL'
asahi-alarm-keyring 20250101-1
hyprland 0.50-1
limine 12.9.0-1
linux-asahi 6.19.1-1
m1n1 1.5.0-1
omarchy-mac-keyring 20260914-2
pacman 7.0.0-1
quickshell-git 0.1-1
uboot-asahi 2026.01-1
voxtype 1.0-1
LOCAL
    # What omarchy-upgrade-to-quattro-mac wired, and the files its setup wrote.
    ln -s "$R$checkout" "$R/usr/share/omarchy"
    for link in omarchy-update omarchy-hw-apple omarchy-upgrade-to-quattro-mac; do
      ln -s "$R$checkout/bin/$link" "$R/usr/bin/$link"
    done
    printf 'export OMARCHY_PATH="%s"\n' "$checkout" >"$R/etc/omarchy.conf"
    unowned "legacy theme" /etc/sddm.conf.d/10-theme.conf
    unowned "HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck)" \
      /etc/mkinitcpio.conf.d/omarchy_hooks.conf
    unowned "legacy profile" /etc/profile.d/omarchy.sh
    unowned "legacy uwsm" /usr/share/uwsm/env.d/10-omarchy
  else
    cat >"$R/var/lib/pacman/local/packages" <<'LOCAL'
asahi-alarm-keyring 20250101-1
hyprland 0.50-1
limine 12.9.0-1
linux-asahi 6.19.1-1
m1n1 1.5.0-1
omarchy 4.0.3rc4-1
omarchy-keyring 20260801-1
omarchy-mac-keyring 20260914-2
omarchy-settings 4.0.3rc4-1
pacman 7.0.0-1
quickshell-git 0.1-1
ttf-jetbrains-mono-nerd-basic 3.4.0-1
uboot-asahi 2026.01-1
voxtype 1.0-1
LOCAL
    owns omarchy /usr/share/omarchy/bin/omarchy-update /usr/share/omarchy/bin/omarchy-upgrade-to-quattro-mac \
      /usr/share/omarchy/default/bash/env-bootstrap /usr/bin/omarchy-update
    owns omarchy-settings /etc/sddm.conf.d/10-theme.conf /etc/mkinitcpio.conf.d/omarchy_hooks.conf /etc/profile.d/omarchy.sh
    owns omarchy-keyring /usr/share/pacman/keyrings/omarchy.gpg /usr/share/pacman/keyrings/omarchy-trusted
    echo "$official" >"$R/usr/share/pacman/keyrings/omarchy-trusted"
    owns ttf-jetbrains-mono-nerd-basic /usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf
    unowned "legacy uwsm" /usr/share/uwsm/env.d/10-omarchy
    # A developer's link to a checkout; root's sudo path runs it.
    printf 'export OMARCHY_PATH="%s"\n' "$checkout" >"$R/etc/omarchy.conf"
    echo "Defaults secure_path=\"$checkout/bin:/usr/local/sbin:/usr/local/bin:/usr/bin\"" >"$R/etc/sudoers.d/omarchy-dev-path"
  fi

  cat >"$R/etc/pacman.conf" <<CONF
[options]
HoldPkg = pacman glibc
Architecture = aarch64
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

# Only explicitly selected Hyprland packages use official edge.
[omarchy]
Usage = Sync
SigLevel = Required DatabaseOptional
Server = file://$F/repos/omarchy

[omarchy-aarch64]
SigLevel = Optional TrustAll
Server = file://$F/repos/omarchy-aarch64

[asahi-alarm]
Include = /etc/pacman.d/mirrorlist.asahi-alarm

[core]
Server = file://$F/repos/core

[extra]
Server = file://$F/repos/extra
CONF
  echo "Server = file://$F/repos/asahi-alarm" >"$R/etc/pacman.d/mirrorlist.asahi-alarm"
  if [[ $layout == "channel" ]]; then
    # rc5's strict fork repository, and [omarchy] as omarchy-upgrade-to-quattro writes it.
    sed -i -e 's/^SigLevel = Optional TrustAll$/SigLevel = PackageRequired DatabaseRequired TrustedOnly/' -e '/^Usage = Sync$/d' \
      -e '/^\[omarchy\]$/,/^Server/s/^SigLevel = Required DatabaseOptional$/SigLevel = Optional TrustAll/' "$R/etc/pacman.conf"
  fi
  # Copies the fork's tools left: arm-package-sources' .bak, the Quattro upgrade's timestamped one.
  printf '[omarchy-aarch64]\nSigLevel = Optional TrustAll\n' >"$R/etc/pacman.conf.bak"
  printf '[omarchy]\nSigLevel = Optional TrustAll\n' >"$R/etc/pacman.conf.omarchy-upgrade-to-quattro.20260801000000.bak"
  cp -r "$tmp/set" "$F/set"
  cat >"$R/etc/omarchy-mac/migration-target" <<TARGET
format=1
type=candidate-set
channel=edge
server=file://$F/repos/omarchy
set=$F/set
fingerprint=$signer
TARGET
  echo apple-silicon >"$F/platform"
  echo "base asahi udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck" >"$F/hooks"
  printf '%s\n' "$R/boot/efi" >"$F/mounts"
  echo "/dev/nvme0n1p6[/@]" >"$F/root-source"
  printf '/dev/nvme0n1p6 part btrfs\n/dev/nvme0n1 disk \n' >"$F/lsblk"
  : >"$F/pacman.log"
  : >"$F/boot.log"
}

checkout_digest() {
  (cd "$R$checkout" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum
}

# Links as well as files: a refusal must leave the checkout wired as it was.
links_digest() {
  (cd "$R" && find . -path ./var/tmp -prune -o -type l -print | LC_ALL=C sort | while read -r link; do
    printf '%s -> %s\n' "$link" "$(readlink "$link")"
  done) | sha256sum
}

legacy_refused() { # description reason-pattern
  local links
  links=$(links_digest)
  refused "$1" "$2"
  [[ $(links_digest) == "$links" ]] || fail "$1: no link changed"
}

# TrustAll anywhere pacman's configuration lives: pacman.conf, every file it
# includes and every copy of it beside it.
trustall_anywhere() {
  local files=("$R/etc/pacman.conf" "$R"/etc/pacman.conf.*) path
  while read -r path; do
    files+=("$R$path")
  done < <(sed -n 's/^Include = //p' "$R/etc/pacman.conf" | sort -u)
  grep -l TrustAll "${files[@]}" 2>/dev/null || true
}

# The core Apple Silicon configuration for SERVER, as the fixtures serve it.
core_conf() {
  OMARCHY_MAC_MIGRATE_ROOT=$R fixture=1 bash -c 'source <(sed -n "/^core_pacman_conf() {/,/^}/p" "$1"); core_pacman_conf "$2"' _ "$ROOT/migrate/src/target.sh" "$1" |
    sed "s|^Server = https://github.com/asahi-alarm.*|Server = file://FIXTURE/repos/asahi-alarm|"
}

# Everything a finished conversion leaves, however it got there.
outcome() {
  local state
  state=$(state_dir)
  cat "$R/var/lib/pacman/local/packages"
  LC_ALL=C sort "$R/var/lib/pacman/local/files"
  sed "s|$F|FIXTURE|g" "$R/etc/pacman.conf"
  sort "$R/etc/pacman.d/gnupg/keys"
  (cd "$R" && find usr/bin usr/share/omarchy usr/share/uwsm etc/sddm.conf.d etc/mkinitcpio.conf.d etc/profile.d etc/sudoers.d \
    usr/share/pacman/keyrings var/cache/omarchy \( -type f -o -type l \) | LC_ALL=C sort | while read -r path; do
    if [[ -L $path ]]; then echo "$path -> $(readlink "$path" | sed "s|$R|ROOT|")"; else echo "$path: $(head -c 80 "$path")"; fi
  done)
  cat "$R/etc/omarchy.conf" "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI" "$R/etc/default/limine"
  (cd "$R/etc" && ls -d pacman.conf*)
  ls "$R/var/lib/pacman/sync"
  [[ ! -e $R/var/lib/pacman/db.lck ]] && echo unlocked
  sed -n 's/^target=//p' "$state/complete"
  (cd "$state/backup" && find . -type f | LC_ALL=C sort)
  sed "s|$R|ROOT|g" "$state/backup/converted/links"
  ls "$state"
  [[ ! -e $R/etc/systemd/system/omarchy-mac-migrate-verify.service ]] && echo "no unit"
  checkout_digest
}

# --- A checkout upgraded to Quattro ------------------------------------------------

new_fixture baseline checkout
before=$(checkout_digest)
output=$(migrate run 2>&1) || fail "a legacy checkout Mac migrates to its reboot" "$output"
grep -q "Reboot to finish the migration to candidate-set apple-test-fixture" <<<"$output" || fail "the run asks for a reboot" "$output"
state=$(state_dir)
[[ $(<"$state/plan/cohort") == "legacy" ]] || fail "the Mac is a legacy omarchy-mac install" "$(cat "$state/plan/cohort")"
pass "an unencrypted legacy Mac with the fork's busybox HOOKS line is not refused"

expected_packages='asahi-alarm-keyring 20250101-1
hyprland 0.51-1
limine 12.9.0-1
limine-mkinitcpio-hook 1.39.0-2
linux-aurora 7.1.12.aurora2-11
m1n1-aurora 1.6.1.aurora1-3
omarchy-dev 4.0.0.r7000.gabc-1.1
omarchy-keyring 20260920-1
omarchy-mac 0.1.0-11.1
omarchy-mac-boot 20261004-1.1
omarchy-settings-dev 4.0.0.r7000.gabc-1.1
pacman 7.0.0-1
quickshell-git 0.2-1
uboot-asahi 2026.07.asahi2-4
voxtype 1.0-1'
[[ $(cat "$R/var/lib/pacman/local/packages") == "$expected_packages" ]] ||
  fail "the checkout becomes the omarchy-dev pair, the fork's builds official ones, and the fork keyring goes" "$(cat "$R/var/lib/pacman/local/packages")"
[[ -d $R/usr/share/omarchy && ! -L $R/usr/share/omarchy ]] || fail "/usr/share/omarchy is the package's, not a link to the checkout"
[[ ! -L $R/usr/bin/omarchy-update ]] && grep -qx "omarchy-dev /usr/bin/omarchy-update" "$R/var/lib/pacman/local/files" ||
  fail "the commands are the package's"
[[ ! -e $R/usr/bin/omarchy-upgrade-to-quattro-mac ]] || fail "links to checkout commands no package ships are gone"
[[ ! -L $R/usr/bin/omarchy-hw-apple ]] && grep -qx "omarchy-mac /usr/bin/omarchy-hw-apple" "$R/var/lib/pacman/local/files" ||
  fail "the legacy detector alias is omarchy-mac's, not a link to the checkout"
[[ $(<"$R/etc/omarchy.conf") == 'export OMARCHY_PATH="/usr/share/omarchy"' ]] || fail "OMARCHY_PATH is the packaged tree" "$(cat "$R/etc/omarchy.conf")"
[[ $(checkout_digest) == "$before" ]] || fail "the checkout itself is untouched"
for path in /etc/profile.d/omarchy.sh /usr/share/uwsm/env.d/10-omarchy; do
  grep -qx "omarchy-settings-dev $path" "$R/var/lib/pacman/local/files" || fail "omarchy-settings-dev owns $path"
  [[ $(<"$R$path") == "omarchy-settings-dev 4.0.0.r7000.gabc-1.1" ]] || fail "the package's $path replaces the setup's"
  [[ $(<"$state/backup/converted/files$path") == legacy* ]] || fail "the setup's own $path is kept in the backup"
done
[[ $(<"$R/etc/sddm.conf.d/10-theme.conf") == "legacy theme" && -f $R/etc/sddm.conf.d/10-theme.conf.pacnew ]] &&
  grep -qx "omarchy-settings-dev /etc/sddm.conf.d/10-theme.conf" "$R/var/lib/pacman/local/files" ||
  fail "a configuration file the package lists in backup= keeps its contents, and the package's lands as .pacnew"
grep -q "encrypt" "$R/etc/mkinitcpio.conf.d/omarchy_hooks.conf" || fail "a file no new package brings is left alone"
[[ $(sed "s|$R|ROOT|g" "$state/backup/converted/links") == "/usr/bin/omarchy-hw-apple	ROOT$checkout/bin/omarchy-hw-apple
/usr/bin/omarchy-update	ROOT$checkout/bin/omarchy-update
/usr/bin/omarchy-upgrade-to-quattro-mac	ROOT$checkout/bin/omarchy-upgrade-to-quattro-mac
/usr/share/omarchy	ROOT$checkout" ]] || fail "every link to the checkout is recorded" "$(cat "$state/backup/converted/links")"
[[ -f $state/backup/converted/files/etc/omarchy.conf ]] || fail "the checkout's omarchy.conf is kept"
grep -q "^transaction omarchy-mac-candidate/omarchy-dev omarchy-mac-candidate/omarchy-settings-dev omarchy-mac-candidate/omarchy-mac " "$F/pacman.log" ||
  fail "the omarchy-dev pair is named from the candidate set" "$(grep transaction "$F/pacman.log")"
grep -q "^transaction .* quickshell-git asahi-alarm-keyring omarchy-keyring$" "$F/pacman.log" ||
  fail "a fork build the official repository carries and the keyrings are named" "$(grep transaction "$F/pacman.log")"
grep -q "^voxtype 1.0-1$" "$state/plan/kept" && ! grep -q "omarchy-mac-keyring" "$state/plan/kept" ||
  fail "a fork build with no official one is kept and listed; the keyring is not" "$(cat "$state/plan/kept")"
pass "a checkout Mac is converted to the omarchy-dev pair, its checkout unwired and its unowned files backed up"

conf=$(sed "s|$F|FIXTURE|g" "$R/etc/pacman.conf")
[[ $conf == "$(core_conf "file://FIXTURE/repos/omarchy")" ]] ||
  fail "pacman.conf is the core Apple Silicon configuration: the fork repository, its TrustAll and [omarchy]'s own SigLevel are gone" \
    "$(diff <(core_conf "file://FIXTURE/repos/omarchy") <(echo "$conf"))"
[[ ! -e $R/var/lib/pacman/sync/omarchy-aarch64.db ]] || fail "the fork's sync database is gone"
! grep -q "^$fork " "$R/etc/pacman.d/gnupg/keys" || fail "the rc4 fork key is gone from the keyring"
grep -q "^$official f$" "$R/etc/pacman.d/gnupg/keys" || fail "the Omarchy key is trusted"
[[ ! -e $R/usr/share/pacman/keyrings/omarchy-mac.gpg && ! -e $R/usr/share/pacman/keyrings/omarchy-mac-trusted ]] ||
  fail "omarchy-mac-keyring is removed, so no populate trusts the fork key again"
[[ $(grep '^transaction \|^remove ' "$F/pacman.log" | cut -d' ' -f1 | xargs) == "transaction remove" ]] && grep -q "^remove omarchy-mac-keyring$" "$F/pacman.log" ||
  fail "the keyring is removed after the transaction that replaced what needed it" "$(cat "$F/pacman.log")"
pass "official trust only: TrustAll, the fork repository, key and keyring are gone"

reboot_into_aurora
output=$(migrate verify 2>&1) || fail "the post-reboot verification completes the migration" "$output"
grep -q "The checkout at $R$checkout is no longer used" <<<"$output" || fail "retire names the unused checkout" "$output"
[[ -f $R/etc/sddm.conf.d/autologin.conf ]] || fail "an administrator's autologin is kept"
[[ -z $(ls "$R/var/cache/omarchy/channels") ]] || fail "the fork's channel transactions are retired"
[[ -z $(trustall_anywhere) ]] || fail "no TrustAll is left in pacman's configuration, its includes or copies of it" "$(trustall_anywhere)"
for file in pacman.conf.bak pacman.conf.omarchy-upgrade-to-quattro.20260801000000.bak; do
  grep -q TrustAll "$state/backup/converted/files/etc/$file" || fail "the fork's $file is kept in the backup"
done
baseline=$(outcome)
output=$(migrate run 2>&1) || fail "a second run succeeds" "$output"
[[ $(outcome) == "$baseline" ]] || fail "a second run changes nothing"
pass "after the reboot the fork's channel state and TrustAll copies are retired, and a second run changes nothing"

! grep -q '^mount \|^umount \|^mkinitcpio ' "$F/boot.log" && [[ ! -e $R/etc/crypttab && ! -e $state/backup/boot-switch ]] &&
  [[ $(cat "$R/etc/default/grub") == 'GRUB_CMDLINE_LINUX=""' && $(cat "$F/mounts") == "$R/boot/efi" ]] ||
  fail "an unencrypted Mac with its ESP at /boot/efi has no boot switch to stage" "$(cat "$F/boot.log")"
grep -q "^dispatch setup-boot$" "$F/boot.log" && grep -q "^limine-boot activate$" "$F/boot.log" ||
  fail "the new runtime's setup-boot activates Limine" "$(cat "$F/boot.log")"
pass "an unencrypted legacy Mac keeps its layout and unlock: Limine is its only boot change"

# --- Interruption at every checkpoint -------------------------------------------

interrupt() { # when point step
  local when=$1 point=$2 step=$3 status=0 output last transactions=1 partial
  new_fixture "kill-$when-$point" checkout
  output=$(migrate_env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$point" -- run 2>&1) || status=$?
  if (( status == 0 )); then
    reboot_into_aurora
    output=$(migrate_env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$point" -- verify 2>&1) || status=$?
  fi
  (( status == 137 )) || fail "the run is killed $when $point" "status $status: $output"
  last=$(tail -n 1 "$(state_dir)/journal" | cut -d' ' -f2-)
  if [[ $when == "after" ]]; then
    [[ $last == "$step done"* ]] || fail "killed $when $point, the journal ends with $step done" "$last"
  else
    [[ $last == "$step begin"* || $last == "repositories boundary" ]] || fail "killed $when $point, the journal ends with $step begun" "$last"
  fi
  finish
  # pacman's own half-extracted files are backed up too, beside the originals.
  partial='^\./converted/files/(usr/share/omarchy/|usr/bin/omarchy-)'
  [[ $(outcome | grep -Ev "$partial") == "$(grep -Ev "$partial" <<<"$baseline")" ]] ||
    fail "killed $when $point, the resumed migration ends where an uninterrupted one does" "$(diff <(echo "$baseline") <(outcome))"
  [[ $point == "extraction" || $(outcome) == "$baseline" ]] || fail "killed $when $point, the backup matches an uninterrupted one"
  [[ $when$point == "midtransaction" || $when$point == "midextraction" ]] && transactions=2
  [[ $(grep -c '^transaction ' "$F/pacman.log") == "$transactions" && $(grep -c '^remove ' "$F/pacman.log") == 1 ]] ||
    fail "killed $when $point: $transactions package transaction(s) and one removal" "$(cat "$F/pacman.log")"
  [[ $(grep '^transaction \|^remove \|^hooks' "$F/pacman.log" | tail -n 1) == "hooks" ]] || fail "killed $when $point: the last transaction's hooks ran"
}

for step in "${steps[@]}"; do
  interrupt after "$step" "$step"
  interrupt during "$step" "$step"
done
for step in backup keyring prefetch repositories boot-chain loader defaults unpin reboot retire; do
  interrupt mid "$step" "$step"
done
interrupt mid loader-leaf loader
for point in unwire convert extraction transaction removals; do
  interrupt mid "$point" transaction
done
pass "a kill -9 at every checkpoint, the conversion's own included, resumes to the same end"

# --- A channel Mac with a dev link ------------------------------------------------

new_fixture channel channel
before=$(checkout_digest)
finish
grep -q "^omarchy-dev 4.0.0.r7000.gabc-1.1$" "$R/var/lib/pacman/local/packages" && grep -q "^omarchy-settings-dev 4.0.0.r7000.gabc-1.1$" "$R/var/lib/pacman/local/packages" &&
  ! grep -q "^omarchy \|^omarchy-settings " "$R/var/lib/pacman/local/packages" ||
  fail "the lane's rc pair is replaced by the omarchy-dev pair" "$(cat "$R/var/lib/pacman/local/packages")"
grep -q "^omarchy-keyring 20260920-1$" "$R/var/lib/pacman/local/packages" && grep -q "^ttf-jetbrains-mono-nerd-basic 3.4.0-2$" "$R/var/lib/pacman/local/packages" ||
  fail "the packages the checkout built move to their official builds" "$(cat "$R/var/lib/pacman/local/packages")"
grep -q "^transaction .* quickshell-git omarchy-keyring ttf-jetbrains-mono-nerd-basic asahi-alarm-keyring$" "$F/pacman.log" ||
  fail "the checkout's own builds are named" "$(grep transaction "$F/pacman.log")"
! grep -q "omarchy-mac-keyring" "$R/var/lib/pacman/local/packages" || fail "the keyring the rc pair depended on is removed"
! grep -q "omarchy-aarch64\|TrustedOnly" "$R/etc/pacman.conf" || fail "the rc5-style fork repository is gone too"
[[ -z $(trustall_anywhere) ]] || fail "the Quattro upgrade's TrustAll on [omarchy] is gone with every other" "$(trustall_anywhere)"
! grep -A2 '^\[omarchy\]$' "$R/etc/pacman.conf" | grep -q SigLevel || fail "[omarchy] inherits the global SigLevel"
! grep -q "^$fork " "$R/etc/pacman.d/gnupg/keys" || fail "the fork key is gone"
[[ ! -e $R/etc/sudoers.d/omarchy-dev-path && $(<"$R/etc/omarchy.conf") == 'export OMARCHY_PATH="/usr/share/omarchy"' ]] ||
  fail "a dev link to a fork checkout no longer runs as root or as Omarchy"
grep -qx "omarchy-settings-dev /usr/share/uwsm/env.d/10-omarchy" "$R/var/lib/pacman/local/files" ||
  fail "an unowned file the setup wrote is taken over"
[[ ! -e $R/etc/mkinitcpio.conf.d/omarchy_hooks.conf ]] || fail "the fork settings' busybox HOOKS line goes with the package"
[[ $(checkout_digest) == "$before" ]] || fail "the checkout is untouched"
pass "a channel Mac with a strict fork repository and a dev link converts to the omarchy-dev pair, keyring and link retired"

# --- The channel the fork's lane names ---------------------------------------------

# Without an administrator's target, the Mac follows the channel its
# [omarchy-aarch64] lane is named after.
lane_fixture() { # name layout channel
  new_fixture "$1" "$2"
  rm "$R/etc/omarchy-mac/migration-target"
  sed -i "s|^Server = file://$F/repos/omarchy-aarch64$|Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/$3|" "$R/etc/pacman.conf"
  cp -r "$F/repos/omarchy" "$F/repos/official-$3"
}

lane_fixture lane-rc channel rc
archive omarchy 4.0.4-1
archive omarchy-mac-boot 20260927-1
output=$(migrate check 2>&1) || fail "an rc lane follows the rc channel" "$output"
grep -q "Ready: run moves this Mac (legacy, grub boot) onto repository file://$F/repos/official-rc (rc)" <<<"$output" ||
  fail "the rc lane's Mac moves to the rc channel" "$output"
grep -q "It installs: omarchy omarchy-settings omarchy-mac " <<<"$output" || fail "the rc channel keeps the stock pair" "$output"

lane_fixture lane-edge channel edge
archive omarchy-dev 4.0.0.r6713.ga85e29a-1
archive omarchy-mac-boot 20260927-1
finish
grep -q "^transaction omarchy/omarchy-dev omarchy/omarchy-settings-dev omarchy/omarchy-mac omarchy/omarchy-mac-boot omarchy/linux-aurora omarchy/m1n1-aurora omarchy/uboot-asahi omarchy/limine-mkinitcpio-hook quickshell-git omarchy-keyring ttf-jetbrains-mono-nerd-basic asahi-alarm-keyring$" "$F/pacman.log" ||
  fail "each official package is named in [omarchy]" "$(grep transaction "$F/pacman.log")"
grep -q "^omarchy-dev 4.0.0.r6713.ga85e29a-1$" "$R/var/lib/pacman/local/packages" && ! grep -q "^omarchy \|omarchy-mac-keyring" "$R/var/lib/pacman/local/packages" ||
  fail "the edge lane's Mac ends on the omarchy-dev pair, fork pair and keyring gone" "$(cat "$R/var/lib/pacman/local/packages")"
grep -q "^download omarchy-dev \|^download omarchy-mac-boot " "$F/pacman.log" || fail "preflight reads the verified archives"
[[ $(sed "s|$F|FIXTURE|g" "$R/etc/pacman.conf") == "$(core_conf "file://FIXTURE/repos/official-edge")" ]] ||
  fail "pacman.conf is the core configuration for the edge channel" "$(cat "$R/etc/pacman.conf")"
[[ $(sed -n 's/^target=//p' "$(state_dir)/complete") == "repository file://$F/repos/official-edge" ]] || fail "the edge channel is the migration's target"
pass "without an administrator's target, the fork lane's channel (stable, rc or edge) is the one this Mac moves to"

# --- Refusals ------------------------------------------------------------------------

new_fixture refusals checkout
rm "$R/usr/share/omarchy"
legacy_refused "a 3.x checkout" "upgrade the 3.x install with omarchy-upgrade-to-quattro-mac first"
new_fixture refusals channel
sed -i 's/^\[options\]$/[options]\nIgnorePkg = omarchy omarchy-settings # omarchy-install-pair/' "$R/etc/pacman.conf"
legacy_refused "a pinned channel install" "holds back omarchy, which the migration changes"
new_fixture refusals channel
: >"$R/var/cache/omarchy/channels/transaction.Stale01/restore-sync"
legacy_refused "an unfinished channel switch" "owes its sync databases a restore"
new_fixture refusals channel
printf '%s:4:\n%s:4:\n' "$fork" 3333333333333333333333333333333333333333 >"$R/usr/share/pacman/keyrings/omarchy-mac-trusted"
legacy_refused "a fork keyring with another key" "trusts 3333333333333333333333333333333333333333, a key this migration does not remove"
new_fixture refusals checkout
printf '\n[custom]\nSigLevel = Optional TrustAll\nServer = file:///custom\n' >>"$R/etc/pacman.conf"
legacy_refused "a TrustAll repository the switch would keep" "\[custom\] accepts untrusted packages"
new_fixture refusals checkout
sed -i '/^\[omarchy-aarch64\]$/,/^Server/d' "$R/etc/pacman.conf"
printf '\nInclude = /etc/pacman.d/fork.conf\n' >>"$R/etc/pacman.conf"
printf '[omarchy-aarch64]\nSigLevel = Optional TrustAll\nServer = file://%s/repos/omarchy-aarch64\n' "$F" >"$R/etc/pacman.d/fork.conf"
legacy_refused "the fork repository an Include configures" "\[omarchy-aarch64\] is configured through an Include"
pass "preflight refuses pre-Quattro and mid-channel-switch legacy Macs, unknown fork keys, untrusted kept and included repositories, changing nothing"

# --- Failures before the switch defer; after it they put things back ---------------

# Before the repository switch a failure sets the attempt aside, nothing
# changed, and the next run starts over.
deferred() { # description reason-pattern
  local status=0 conf packages
  conf=$(cat "$R/etc/pacman.conf")
  packages=$(cat "$R/var/lib/pacman/local/packages")
  output=$(migrate run 2>&1) || status=$?
  (( status == 75 )) && grep -q -- "$2" <<<"$output" || fail "$1: the migration defers" "status $status: $output"
  [[ $(cat "$R/etc/pacman.conf") == "$conf" && $(cat "$R/var/lib/pacman/local/packages") == "$packages" ]] ||
    fail "$1: repositories and packages are untouched"
  [[ -L $R/usr/share/omarchy ]] && grep -q "^$fork f$" "$R/etc/pacman.d/gnupg/keys" || fail "$1: the checkout and the fork key are untouched"
  [[ ! -e $(state_dir)/journal && -n $(ls -d "$(state_dir)"/history/aborted-* 2>/dev/null) ]] || fail "$1: the attempt is set aside"
  [[ $(migrate status) == *"The last run deferred: "*"$2"* ]] || fail "$1: status says why it deferred" "$(migrate status)"
}

new_fixture fork-signed checkout
sed -i "s/^quickshell-git 0.2-1 .*/quickshell-git 0.2-1 $fork/" "$F/repos/omarchy/omarchy.db"
deferred "a package only the fork key signed" "cannot download and verify the target set"
grep -q "quickshell-git: signature from \"$fork\" is unknown trust" <<<"$output" || fail "the prefetch refuses the fork signature" "$output"
pass "packages are verified against the trust the switch leaves: one signed only by the fork key defers the migration"

new_fixture owned checkout
echo "voxtype /usr/share/uwsm/env.d/10-omarchy" >>"$R/var/lib/pacman/local/files"
deferred "a file a kept package owns" "would overwrite /usr/share/uwsm/env.d/10-omarchy, which voxtype owns and keeps"
pass "a file another package keeps owning is never overwritten"

new_fixture needs-keyring checkout
echo "voxtype 1.0-1 omarchy-mac-keyring" >>"$F/depends"
deferred "a kept package that needs the fork keyring" "rehearsed removal of omarchy-mac-keyring failed"
pass "the keyring's removal is rehearsed: a package still needing it defers the migration before any change"

new_fixture prepare-fails checkout
kill_after repositories
mv "$(state_dir)/cache/pkg" "$F/pkg.moved"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "the archive of .* is not in the cache" <<<"$output" || fail "a missing archive stops the transaction" "status $status: $output"
[[ -L $R/usr/share/omarchy && -L $R/usr/bin/omarchy-update && $(<"$R/etc/omarchy.conf") == "export OMARCHY_PATH=\"$checkout\"" ]] ||
  fail "a conversion that cannot be prepared leaves the checkout wired"
mv "$F/pkg.moved" "$(state_dir)/cache/pkg"
finish
[[ -d $R/usr/share/omarchy && ! -L $R/usr/share/omarchy ]] || fail "the retried transaction converts the checkout"
pass "a conversion that cannot be prepared changes nothing, and the retry converts"

new_fixture pruned checkout
echo cached >"$R/var/cache/pacman/pkg/quickshell-git-0.2-1-aarch64.pkg.tar.zst"
kill_after prefetch
[[ $(stat -c %i "$(state_dir)/cache/pkg/quickshell-git-0.2-1-aarch64.pkg.tar.zst") == $(stat -c %i "$R/var/cache/pacman/pkg/quickshell-git-0.2-1-aarch64.pkg.tar.zst") ]] ||
  fail "an archive only pacman's cache holds is linked into the migration's"
rm "$R/var/cache/pacman/pkg/quickshell-git-0.2-1-aarch64.pkg.tar.zst"
finish
pass "the archives the conversion reads survive pacman's cache being pruned"

new_fixture pacman-fails channel
: >"$F/fail-transaction"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && [[ -f $R/etc/sudoers.d/omarchy-dev-path && $(<"$R/etc/omarchy.conf") == "export OMARCHY_PATH=\"$checkout\"" ]] ||
  fail "a failed transaction gives a dev link back its OMARCHY_PATH and sudo path" "status $status: $output"
rm "$F/fail-transaction"
finish
[[ ! -e $R/etc/sudoers.d/omarchy-dev-path ]] || fail "the retry drops the dev link's sudo path"

new_fixture pacman-fails checkout
kill_after repositories
: >"$F/fail-transaction"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "the package transaction failed" <<<"$output" || fail "a failed transaction fails the step" "status $status: $output"
[[ $(readlink "$R/usr/share/omarchy") == "$R$checkout" && $(readlink "$R/usr/bin/omarchy-update") == "$R$checkout/bin/omarchy-update" ]] ||
  fail "the checkout's links come back when pacman fails"
grep -q "^IgnorePkg = " "$R/etc/pacman.conf" || fail "the guard stays while the transaction is owed"
rm "$F/fail-transaction"
finish
[[ -d $R/usr/share/omarchy && ! -L $R/usr/share/omarchy ]] || fail "the retried transaction converts the checkout"
pass "a failed transaction puts the checkout's links and a dev link's paths back, and the retry converts"

# --- The boot switch --------------------------------------------------------------

luks_uuid=5b1f0c2e-8a44-4f1d-9d7e-3c2a1b0e9f11
fs_uuid=0a1b2c3d-4e5f-4061-8a9b-c0d1e2f3a4b5
converged_hooks="base systemd autodetect microcode modconf kms keyboard sd-vconsole block asahi omarchy-vendorfw omarchy-mac-encrypt sd-encrypt filesystems fsck"
fork_hooks="base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck"

# The ESP mounted at /boot, as omarchy-system-boot-to-esp leaves it: GRUB, the
# Asahi kernel and its busybox image live on it, and the root's own /boot is an
# empty directory beneath. The fixture's mount stand-ins link a mountpoint to
# $F/esp. HOOKS and images come from omarchy-mac-boot's real resolver over
# mkinitcpio.conf and the drop-ins (the Apple boot package's and the fork's
# omarchy_hooks.conf), and the transaction runs the kernel's install hook.
esp_at_boot() {
  local hooks=$1
  rm "$F/hooks"
  : >"$F/kernel-hook"
  install -m 755 "$mac_boot/bin/omarchy-mac-initramfs-hooks" "$mac_boot/bin/omarchy-mac-limine-cmdline" "$R/usr/bin/"
  cp "$mac_boot"/mkinitcpio.conf.d/*.conf "$R/etc/mkinitcpio.conf.d/"
  mkdir -p "$F/esp" "$F/covered"
  mv "$R/boot/efi/EFI" "$R/boot/efi/m1n1" "$R/boot/grub" "$F/esp/"
  rmdir "$R/boot/efi"
  mv "$R/boot" "$F/covered/_boot"
  ln -s "$F/esp" "$R/boot"
  printf '%s\n' "$R/boot" >"$F/mounts"
  echo UUID=4A1B-2C3D >"$F/esp-device"
  echo "aurora kernel 7.1.12" >"$R/usr/lib/modules/7.1.12-aurora/vmlinuz"
  echo "asahi kernel 6.19.1" >"$F/esp/vmlinuz-linux-asahi"
  printf 'MODULES=(btrfs)\nHOOKS=(%s)\n' "$hooks" >"$R/etc/mkinitcpio.conf"
  printf 'UUID=%s / btrfs rw,noatime,compress=zstd:3,subvol=/@ 0 0\nUUID=4A1B-2C3D /boot vfat rw,relatime,fmask=0022,dmask=0022 0 2\n' "$fs_uuid" >"$R/etc/fstab"
  # The fork's line, which sorts after every Apple drop-in and sets HOOKS outright.
  printf 'HOOKS=(%s)\n' "$fork_hooks" >"$R/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
  OMARCHY_MAC_MIGRATE_ROOT=$R MIGRATE_FIXTURE=$F PATH="$stubs:$PATH" mkinitcpio -p linux-asahi >/dev/null
  : >"$F/boot.log"
  # omarchy-mac-boot's setup-boot through the dispatcher: the menu's kernel line
  # derived from GRUB's defaults by the real omarchy-mac-limine-cmdline, and a
  # UKI carrying the kernel line and /boot's kernel and initramfs. It needs the
  # ESP at /boot/efi.
  cat >"$F/setup-boot-leaf" <<'LEAF'
root=$OMARCHY_MAC_MIGRATE_ROOT
[[ -d $root/boot/efi/EFI/BOOT ]] || { echo "limine-boot: the ESP is not mounted at /boot/efi" >&2; exit 1; }
echo "limine-boot activate" >>"$MIGRATE_FIXTURE/boot.log"
printf 'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]=""\n' >"$root/etc/default/limine"
OMARCHY_GRUB_DEFAULT=$root/etc/default/grub OMARCHY_LIMINE_DEFAULT=$root/etc/default/limine OMARCHY_FSTAB=$root/etc/fstab \
  "$root/usr/bin/omarchy-mac-limine-cmdline" || exit 1
if [[ ${OMARCHY_MAC_MIGRATE_KILL_MID:-} == "loader-leaf" && ! -e $MIGRATE_FIXTURE/killed-in-leaf ]]; then
  : >"$MIGRATE_FIXTURE/killed-in-leaf"
  kill -9 "$PPID" $$
fi
limine-update || exit 1
{ sed -n 's/^KERNEL_CMDLINE\[default\]=//p' "$root/etc/default/limine"; cat "$root/boot/vmlinuz-linux-aurora" "$root/boot/initramfs-linux-aurora.img"; } \
  >"$root/boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
cp "$root/usr/share/limine/BOOTAA64.EFI" "$root/boot/efi/EFI/BOOT/BOOTAA64.EFI"
LEAF
}

# An encrypted legacy Mac as the quattro guided installer (#155) left it: the
# root is LUKS2 opened as root by cryptdevice= from GRUB's defaults, and busybox
# encrypt is in mkinitcpio.conf's own HOOKS and the fork's omarchy_hooks.conf.
encrypted_fixture() {
  new_fixture "$1" "${2:-checkout}"
  esp_at_boot "base asahi udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck"
  echo "$luks_uuid" >"$F/luks-uuid"
  printf 'GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=UUID=%s:root:allow-discards loglevel=3 quiet splash"\nGRUB_CMDLINE_LINUX=""\n' \
    "$luks_uuid" >"$R/etc/default/grub"
  printf 'menuentry Omarchy {\n  linux /vmlinuz-linux-asahi root=UUID=%s rw rootflags=subvol=@ cryptdevice=UUID=%s:root:allow-discards\n  initrd /initramfs-linux-asahi.img\n}\n' \
    "$fs_uuid" "$luks_uuid" >"$F/esp/grub/grub.cfg"
  printf '/dev/mapper/root crypt btrfs\n/dev/nvme0n1p6 part crypto_LUKS\n/dev/nvme0n1 disk \n' >"$F/lsblk"
  echo "/dev/mapper/root[/@]" >"$F/root-source"
}

# GRUB's chain on the ESP still boots and unlocks: GRUB holds U-Boot's slot,
# its menu passes cryptdevice=, and every image on the ESP is busybox with
# encrypt.
grub_boots_esp() {
  local image found=0
  [[ $(cat "$F/esp/EFI/BOOT/BOOTAA64.EFI") == "grub" ]] && grep -q "cryptdevice=UUID=$luks_uuid:root" "$F/esp/grub/grub.cfg" || return 1
  for image in "$F"/esp/initramfs-linux-*.img; do
    [[ -f $image ]] || continue
    grep -qx hooks/encrypt "$image" && grep -qx init_functions "$image" || return 1
    found=1
  done
  (( found ))
}

# Everything the boot switch leaves, however it got there.
switch_outcome() {
  outcome
  cat "$R/etc/fstab" "$R/etc/default/grub" "$R/etc/mkinitcpio.conf"
  cat "$R/etc/crypttab" 2>/dev/null || echo "no crypttab"
  ls "$R/etc/mkinitcpio.conf.d"
  (cd "$R/boot" && find . -type f | LC_ALL=C sort && cat initramfs-linux-aurora.img)
  (cd "$F/esp" && find . -type f | LC_ALL=C sort && cat EFI/Linux/omarchy_linux-aurora.efi)
  sed "s|$R|ROOT|" "$F/mounts"
  [[ -L $R/boot/efi && ! -L $R/boot ]] && echo "the ESP at /boot/efi, the root's /boot beneath"
  grep '^cryptsetup' "$F/pacman.log" | cut -d' ' -f2 | LC_ALL=C sort -u
}

encrypted_fixture encrypted checkout
output=$(migrate run 2>&1) || fail "an encrypted legacy Mac migrates to its reboot" "$output"
grep -q "Reboot to finish" <<<"$output" || fail "the encrypted Mac's run asks for a reboot" "$output"
state=$(state_dir)
[[ $(<"$state/plan/adapter/unlock") == "busybox $luks_uuid 1" && $(<"$state/plan/esp") == "/boot" ]] ||
  fail "the plan records the busybox unlock and the ESP at /boot" "$(cat "$state/plan/adapter/unlock" "$state/plan/esp")"
pass "an encrypted legacy Mac (busybox encrypt, /boot on the ESP) is not refused"

[[ $(sed "s|$R|ROOT|" "$F/mounts") == "ROOT/boot/efi" && -L $R/boot/efi && ! -L $R/boot ]] &&
  grep -qx "UUID=4A1B-2C3D /boot/efi vfat rw,relatime,fmask=0022,dmask=0022 0 2" "$R/etc/fstab" ||
  fail "the ESP moves from /boot to /boot/efi, in fstab and mounted" "$(cat "$R/etc/fstab" "$F/mounts")"
[[ $(<"$R/boot/vmlinuz-linux-aurora") == "aurora kernel 7.1.12" && -d $R/boot/grub ]] ||
  fail "the root's /boot gets the Aurora kernel and the directory update-grub needs"
[[ $(sed -n 's/^HOOKS //p' "$R/boot/initramfs-linux-aurora.img") == "$converged_hooks" ]] ||
  fail "the root's /boot gets the converged systemd image the Apple boot package composes" "$(cat "$R/boot/initramfs-linux-aurora.img")"
[[ $(cat "$R/etc/crypttab") == "root UUID=$luks_uuid none luks,discard" ]] || fail "crypttab names the root's LUKS partition, discards kept" "$(cat "$R/etc/crypttab")"
[[ $(cat "$R/etc/default/grub") == "GRUB_DEFAULT=0
GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet splash\"
GRUB_CMDLINE_LINUX=\"rd.luks.name=$luks_uuid=root rd.luks.options=$luks_uuid=discard\"" ]] ||
  fail "GRUB's defaults trade cryptdevice= for rd.luks.name= and rd.luks.options=" "$(cat "$R/etc/default/grub")"
grep -qx "HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)" "$R/etc/mkinitcpio.conf" &&
  [[ ! -e $R/etc/mkinitcpio.conf.d/omarchy_hooks.conf && -f $state/backup/boot-switch/files/etc/mkinitcpio.conf.d/omarchy_hooks.conf ]] ||
  fail "busybox encrypt and asahi leave mkinitcpio.conf and the fork's omarchy_hooks.conf goes to the backup" "$(cat "$R/etc/mkinitcpio.conf")"
for path in etc/fstab etc/default/grub etc/mkinitcpio.conf; do
  grep -q "cryptdevice\|encrypt\|/boot vfat" "$state/backup/boot-switch/files/$path" || fail "the switch keeps the original $path"
done
[[ -f $state/backup/boot-switch/absent/etc/crypttab ]] || fail "the switch records that crypttab did not exist"
pass "the ESP moves to /boot/efi and the unlock to crypttab, rd.luks.name= and the converged systemd image, each original kept"

uki=$(cat "$F/esp/EFI/Linux/omarchy_linux-aurora.efi")
[[ $(head -n 1 <<<"$uki") == "\"root=UUID=$fs_uuid rw rootflags=subvol=@ rd.luks.name=$luks_uuid=root rd.luks.options=$luks_uuid=discard loglevel=3 quiet splash\"" ]] &&
  grep -qx "aurora kernel 7.1.12" <<<"$uki" && grep -qx "usr/lib/systemd/system-generators/systemd-cryptsetup-generator" <<<"$uki" ||
  fail "Limine's UKI boots Aurora with the systemd image and unlocks the root by rd.luks.name=, without cryptdevice=" "$uki"
[[ $(cat "$F/esp/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" && -e $R/var/lib/omarchy/limine.enabled ]] || fail "Limine takes U-Boot's slot"
grep -q "^HOOKS $fork_hooks$" "$F/esp/initramfs-linux-aurora.img" && grep -qx hooks/encrypt "$F/esp/initramfs-linux-aurora.img" ||
  fail "the transaction still built the busybox image GRUB boots" "$(cat "$F/esp/initramfs-linux-aurora.img")"
[[ $(grep -E '^(mkinitcpio|update-grub|boot-check|umount|mount|dispatch setup-boot|limine-boot)' "$F/boot.log" | tr '\n' '|') == \
  "boot-check pending --boot-chain|mkinitcpio -p linux-aurora|update-grub |boot-check pending --boot-chain linux-aurora|umount /boot|mount /boot/efi|mkinitcpio -p linux-aurora|dispatch setup-boot|limine-boot activate|boot-check pending --boot-chain linux-aurora|boot-check pending --boot-chain linux-aurora|" ]] ||
  fail "the busybox image and GRUB are rebuilt and checked, then the ESP moves and the new image is built, before setup-boot gives Limine the slot" "$(cat "$F/boot.log")"
[[ $(grep '^cryptsetup' "$F/pacman.log" | cut -d' ' -f2 | sort -u | xargs) == "luksHeaderBackup luksUUID" ]] ||
  fail "the LUKS header, keyslots and passphrase are never changed, only backed up and read" "$(grep cryptsetup "$F/pacman.log")"
pass "Limine's UKI unlocks the same LUKS root with its passphrase through sd-encrypt; the header is only backed up"

reboot_into_aurora
output=$(migrate verify 2>&1) || fail "the encrypted Mac's migration completes after its reboot" "$output"
[[ -f $state/complete ]] || fail "the encrypted Mac's migration completes"
[[ ! -e $F/esp/vmlinuz-linux-aurora && ! -e $F/esp/initramfs-linux-aurora.img && ! -e $F/esp/vmlinuz-linux-asahi && ! -e $F/esp/grub ]] &&
  [[ -f $F/esp/m1n1/boot.bin && -f $F/esp/EFI/BOOT/BOOTAA64.EFI && -f $F/esp/EFI/Linux/omarchy_linux-aurora.efi ]] ||
  fail "retire removes the kernels and GRUB the moved ESP still carried, and keeps m1n1, Limine and the UKI" "$(cd "$F/esp" && find . -type f)"
tar -tf "$state/backup/esp.tar" | grep -q '^./grub/grub.cfg$' && tar -tf "$state/backup/esp.tar" | grep -q '^./vmlinuz-linux-asahi$' ||
  fail "the backup holds the ESP as it was, GRUB's chain included"
[[ ! -e $state/backup/boot.tar ]] || fail "an ESP at /boot is backed up once"
encrypted_baseline=$(switch_outcome)
output=$(migrate run 2>&1) || fail "a second run succeeds" "$output"
[[ $(switch_outcome) == "$encrypted_baseline" ]] || fail "a second run changes nothing" "$(diff <(echo "$encrypted_baseline") <(switch_outcome))"
pass "after the verified reboot the moved ESP's old kernels and GRUB are retired, and a second run changes nothing"

# A channel install, whose fork omarchy-settings owned omarchy_hooks.conf: the
# transaction takes it away with the package.
encrypted_fixture encrypted-channel channel
finish
[[ $(sed -n 's/^HOOKS //p' "$R/boot/initramfs-linux-aurora.img") == "$converged_hooks" ]] ||
  fail "the Apple drop-ins move the channel Mac's line to systemd and sd-encrypt too" "$(cat "$R/boot/initramfs-linux-aurora.img")"
[[ $(cat "$R/etc/crypttab") == "root UUID=$luks_uuid none luks,discard" && ! -e $R/etc/mkinitcpio.conf.d/omarchy_hooks.conf ]] ||
  fail "the channel Mac unlocks through crypttab with no busybox line left"
pass "an encrypted channel Mac switches its unlock the same way"

# --- The boot switch cut short ------------------------------------------------------

switch_interrupt() { # when point step
  local when=$1 point=$2 step=$3 status=0 output last
  encrypted_fixture "switch-kill-$when-$point"
  output=$(migrate_env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$point" -- run 2>&1) || status=$?
  if (( status == 0 )); then
    reboot_into_aurora
    output=$(migrate_env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$point" -- verify 2>&1) || status=$?
  fi
  (( status == 137 )) || fail "the run is killed $when $point" "status $status: $output"
  last=$(tail -n 1 "$(state_dir)/journal" | cut -d' ' -f2-)
  if [[ $when == "after" ]]; then
    [[ $last == "$step done"* ]] || fail "killed $when $point, the journal ends with $step done" "$last"
  else
    [[ $last == "$step begin"* || $last == "repositories boundary" ]] || fail "killed $when $point, the journal ends with $step begun" "$last"
  fi
  if [[ ! -e $R/var/lib/omarchy/limine.enabled || $(cat "$F/esp/EFI/BOOT/BOOTAA64.EFI") == "grub" ]]; then
    grub_boots_esp || fail "killed $when $point before Limine took the slot, GRUB's chain still unlocks the root" "$(cd "$F/esp" && find . -type f)"
  fi
  finish
  [[ $(switch_outcome) == "$encrypted_baseline" ]] ||
    fail "killed $when $point, the resumed switch ends where an uninterrupted one does" "$(diff <(echo "$encrypted_baseline") <(switch_outcome))"
}

for step in "${steps[@]}"; do
  switch_interrupt after "$step" "$step"
  switch_interrupt during "$step" "$step"
done
for point in backup transaction boot-chain loader defaults unpin reboot retire; do
  switch_interrupt mid "$point" "$point"
done
for point in esp-fstab esp-unmounted unlock initramfs loader-leaf; do
  switch_interrupt mid "$point" loader
done
pass "a kill -9 anywhere in the switch leaves GRUB's chain unlocking the root until Limine takes the slot, and resumes to the same end"

# --- A failed stage leaves GRUB --------------------------------------------------

# Everything GRUB's chain and the root's configuration read, as before the stage.
before_stage() {
  (cd "$F/esp" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
  (cd "$R" && sha256sum etc/fstab etc/default/grub etc/mkinitcpio.conf etc/mkinitcpio.conf.d/*)
  cat "$R/etc/crypttab" 2>/dev/null || echo "no crypttab"
  (cd "$R/boot" && find . | LC_ALL=C sort)
  (cd "$F/covered/_boot" 2>/dev/null && find . | LC_ALL=C sort)
  sed "s|$R|ROOT|" "$F/mounts"
  [[ -L $R/boot ]] && echo "the ESP at /boot"
}

stage_fails() { # description fixture-change reason-pattern
  local status=0 output snapshot
  encrypted_fixture "stage-fails-$1"
  kill_after boot-chain
  eval "$2"
  snapshot=$(before_stage)
  output=$(migrate run 2>&1) || status=$?
  (( status == 1 )) && grep -q -- "$3" <<<"$output" && grep -q "GRUB is still the loader" <<<"$output" ||
    fail "$1: the loader step fails and says GRUB boots" "status $status: $output"
  [[ $(before_stage) == "$snapshot" ]] || fail "$1: the stage is undone, the ESP back at /boot" "$(diff <(echo "$snapshot") <(before_stage))"
  grub_boots_esp && [[ ! -e $R/var/lib/omarchy/limine.enabled ]] || fail "$1: GRUB's chain still unlocks the root"
  [[ $(migrate status) == *"failed at loader"* ]] || fail "$1: status names the failed loader step" "$(migrate status)"
}

stage_fails mkinitcpio ': >"$F/mkinitcpio-fail"' "mkinitcpio -p linux-aurora failed"
rm "$F/mkinitcpio-fail"
finish
[[ $(switch_outcome) == "$encrypted_baseline" ]] || fail "the retried switch ends where an uninterrupted one does" "$(diff <(echo "$encrypted_baseline") <(switch_outcome))"
stage_fails limine ': >"$F/limine-activation-fail"' "Limine could not be activated"
rm "$F/limine-activation-fail"
finish
[[ $(switch_outcome) == "$encrypted_baseline" ]] || fail "the retried activation ends where an uninterrupted one does" "$(diff <(echo "$encrypted_baseline") <(switch_outcome))"
stage_fails local-hooks 'printf "HOOKS+=(encrypt)\n" >"$R/etc/mkinitcpio.conf.d/99-local.conf"' "do not unlock the root through systemd"
# The ESP cannot leave /boot: nothing on it may be removed on the way back.
stage_fails umount-busy ': >"$F/umount-busy"' "cannot unmount the ESP from /boot"
[[ ! -e $(state_dir)/backup/boot-switch ]] || fail "an undone stage keeps no stale originals for the next"
rm "$F/umount-busy"
finish
[[ $(switch_outcome) == "$encrypted_baseline" ]] || fail "the retried move ends where an uninterrupted one does" "$(diff <(echo "$encrypted_baseline") <(switch_outcome))"
pass "a stage or activation that fails is undone, GRUB keeps booting the Mac, and the retry finishes"

# --- An unencrypted Mac with its ESP at /boot ---------------------------------------

new_fixture plain-esp-boot checkout
esp_at_boot "base asahi udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck"
hooks_before=$(OMARCHY_MAC_MIGRATE_ROOT=$R MIGRATE_FIXTURE=$F PATH="$stubs:$PATH" omarchy-mac-initramfs-hooks)
grub_before=$(cat "$R/etc/default/grub")
finish
[[ -L $R/boot/efi && ! -L $R/boot ]] && grep -q " /boot/efi vfat " "$R/etc/fstab" || fail "an unencrypted Mac's ESP moves to /boot/efi too"
[[ ! -e $R/etc/crypttab && $(cat "$R/etc/default/grub") == "$grub_before" ]] && ! grep -q '^cryptsetup' "$F/pacman.log" ||
  fail "an unencrypted Mac stays unencrypted: no crypttab, no LUKS, its kernel line kept"
[[ $(sed -n 's/^HOOKS //p' "$R/boot/initramfs-linux-aurora.img") == "$hooks_before" ]] ||
  fail "an unencrypted Mac keeps its HOOKS" "$(cat "$R/boot/initramfs-linux-aurora.img")"
[[ $(cat "$F/esp/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" ]] && grep -q "^\"root=UUID=$fs_uuid rw rootflags=subvol=@\"$" "$F/esp/EFI/Linux/omarchy_linux-aurora.efi" ||
  fail "an unencrypted Mac boots Aurora's UKI from Limine with no unlock" "$(cat "$F/esp/EFI/Linux/omarchy_linux-aurora.efi")"
pass "an unencrypted Mac with its ESP at /boot moves it and boots Limine, and stays unencrypted"

# --- Refusals of an encrypted Mac ----------------------------------------------------

encrypted_fixture refusals
sed -i "s/:root:allow-discards/:cryptroot/" "$R/etc/default/grub"
legacy_refused "a mapping other than root" "do not pass the one cryptdevice=UUID=$luks_uuid:root"
encrypted_fixture refusals
sed -i "s/^GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"cryptkey=rootfs:\/key\"/" "$R/etc/default/grub"
legacy_refused "a key file" "found: cryptkey=rootfs:/key cryptdevice"
encrypted_fixture refusals
sed -i "s/$luks_uuid:root/0000-1111:root/" "$R/etc/default/grub"
legacy_refused "another LUKS partition" "do not pass the one cryptdevice=UUID=$luks_uuid:root"
encrypted_fixture refusals
sed -i 's/ encrypt / /' "$R/etc/mkinitcpio.conf"
legacy_refused "busybox encrypt only in a drop-in" "not in /etc/mkinitcpio.conf's own HOOKS"
encrypted_fixture refusals
printf 'root UUID=0000-1111 none luks\n' >"$R/etc/crypttab"
legacy_refused "crypttab naming another root" "/etc/crypttab names another root"
encrypted_fixture refusals
sed -i 's/loglevel=3/loglevel=$LEVEL/' "$R/etc/default/grub"
legacy_refused "a kernel line with shell expansion" "uses shell expansion"
encrypted_fixture refusals
: >"$R/var/lib/omarchy/limine.enabled"
printf 'KERNEL_CMDLINE[default]=""\n' >"$R/etc/default/limine"
legacy_refused "a Limine Mac with its ESP at /boot" "moves those only on a GRUB Mac"
encrypted_fixture refusals
sed -i '/ \/boot vfat /d' "$R/etc/fstab"
legacy_refused "an ESP at /boot fstab does not mount" "no single vfat line mounting it there"
new_fixture refusals checkout
printf '/dev/mapper/root crypt btrfs\n/dev/nvme0n1p6 part crypto_LUKS\n/dev/nvme0n1 disk \n' >"$F/lsblk"
echo "/dev/mapper/root[/@]" >"$F/root-source"
echo "$luks_uuid" >"$F/luks-uuid"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=UUID=%s:root"\n' "$luks_uuid" >"$R/etc/default/grub"
printf 'HOOKS=(base udev block encrypt filesystems)\n' >"$R/etc/mkinitcpio.conf"
legacy_refused "an encrypted Mac whose ESP is at /boot/efi" "kernels are not on the ESP mounted at /boot"
pass "preflight refuses encrypted legacy Macs outside the guided installer's layout, changing nothing"
