#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-mac-migrate moves an mx-mac Mac, as the M1 Pro runs it, onto a signed
# target set: the fork's omarchy-dev pair and bundle, its signed [omarchy] and
# [omarchy-aurora] releases and keys, Aurora, Limine and an encrypted root.
# The fixture root is staged and driven as in mac-migrate-test.sh, with the
# same stand-ins; the fake pacman rejects a database beside a signature that
# does not match it, as pacman does.
require_command gpg
require_command gpgv
require_command jq
require_command flock

fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'gpgconf --homedir "$tmp/signer" --kill gpg-agent 2>/dev/null; rm -rf "$tmp"' EXIT
stubs=$ROOT/test/fixtures/migrate/bin
steps=(preflight backup keyring prefetch repositories transaction boot-chain loader reboot retire)
official=40DFB630FF42BCFFB047046CF0134EE680CAC571
fork_key=C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC
release_key=5983B1CA32CB778F4D74D24ECFF35022CA5B5959

mkdir -m 700 "$tmp/signer"
gpg --batch --homedir "$tmp/signer" --pinentry-mode loopback --passphrase '' --quick-gen-key "Migration test signer" ed25519 sign 1d 2>/dev/null
signer=$(gpg --batch --homedir "$tmp/signer" --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')

# The candidate set as tools/release/candidate-set signs it.
make_set() {
  local dir=$1 name version file entries=()
  mkdir -p "$dir"
  while read -r name version; do
    file="$name-$version-aarch64.pkg.tar.zst"
    head -c 512 /dev/urandom >"$dir/$file"
    entries+=("$(jq -n --arg name "$name" --arg version "$version" --arg filename "$file" --arg sha256 "$(sha256sum "$dir/$file" | cut -d' ' -f1)" \
      '{name: $name, version: $version, filename: $filename, sha256: $sha256}')")
    gpg --batch --homedir "$tmp/signer" --detach-sign --no-armor -o "$dir/$file.sig" "$dir/$file" 2>/dev/null
  done <<'SET'
omarchy 4.0.0.alpha.quattro.r1.gabc-1.1
omarchy-settings 4.0.0.alpha.quattro.r1.gabc-1.1
omarchy-mac 0.1.0-5.1
omarchy-mac-boot 20260926-1.43
linux-aurora 7.1.12.aurora2-10
linux-aurora-headers 7.1.12.aurora2-10
m1n1-aurora 1.6.1.aurora1-3
uboot-asahi 2026.07.asahi2-4
limine-mkinitcpio-hook 1.39.0-2
pinta 3.1.2-1.1
avd-fw 0.1-1
SET
  printf '%s\n' "${entries[@]}" | jq -s '{schema: 1, set: "apple-test-fixture", packages: .}' >"$dir/manifest.json.new"
  jq --arg digest "$(jq -r '.packages[] | "\(.name) \(.version) \(.filename) \(.sha256)"' "$dir/manifest.json.new" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)" \
    '.set_sha256 = $digest' "$dir/manifest.json.new" >"$dir/manifest.json"
  rm "$dir/manifest.json.new"
  jq -n --slurpfile manifest "$dir/manifest.json" --arg fpr "$signer" --arg sha "$(sha256sum "$dir/manifest.json" | cut -d' ' -f1)" \
    '{schema: 1, manifest_sha256: $sha, set_sha256: $manifest[0].set_sha256, signer: {fingerprint: $fpr},
      signatures: [$manifest[0].packages[] | {file: .filename}]}' >"$dir/signing.json"
  gpg --batch --homedir "$tmp/signer" --detach-sign --no-armor -o "$dir/signing.json.sig" "$dir/signing.json" 2>/dev/null
  gpg --batch --homedir "$tmp/signer" --armor --export "$signer" >"$dir/candidate-signing-key.asc" 2>/dev/null
}
make_set "$tmp/set"

# repo DIR [NAME]: a file:// repository in $F/repos/DIR whose database is NAME.db.
repo() {
  mkdir -p "$F/repos/$1"
  cat >"$F/repos/$1/${2:-$1}.db"
}

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
Server = file://$F/repos/core

[extra]
Server = file://$F/repos/extra
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
# Aurora and U-Boot from the fork's releases, Limine in the loader slot, the
# encrypted root unlocked by sd-encrypt, and the omarchy-mac-boot that carries
# this engine already installed.
new_fixture() {
  F=$tmp/$1
  R=$F/root
  rm -rf "$F"
  mkdir -p "$R"
  bash "$ROOT/install" "$R"
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
  printf 'format=1\nchannel=rc\nkernel=linux-aurora\n' >"$R/var/lib/omarchy/apple-silicon-channel"
  printf 'format=1\nlane=rc\n' >"$R/var/lib/omarchy/apple-silicon-aurora-lane"
  printf 'format=1\nencrypt=1\n' >"$R/var/lib/omarchy/mac-first-boot/install.conf"
  for keyring in archlinuxarm asahi-alarm omarchy; do
    : >"$R/usr/share/pacman/keyrings/$keyring.gpg"
  done
  echo 1111111111111111111111111111111111111111 >"$R/usr/share/pacman/keyrings/archlinuxarm-trusted"
  echo 2222222222222222222222222222222222222222 >"$R/usr/share/pacman/keyrings/asahi-alarm-trusted"
  echo "$official" >"$R/usr/share/pacman/keyrings/omarchy-trusted"
  printf '%s f\n' 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 "$official" "$fork_key" "$release_key" \
    >"$R/etc/pacman.d/gnupg/keys"

  cat >"$R/var/lib/pacman/local/packages" <<'LOCAL'
hyprland 0.50-1
limine 12.9.0-1
limine-mkinitcpio-hook 1.36.0-3
linux-aurora 7.1.12.aurora2-7
linux-aurora-headers 7.1.12.aurora2-7
m1n1-aurora 1.6.1.aurora1-2
mise 2026.9.4-1
obs-studio 32.2.2-1
omarchy-dev 4.0.4.r7081.gca187b0-1
omarchy-keyring 20251027-1
omarchy-mac-boot 20260926-1.43
omarchy-nvim 2026.8.1-3
omarchy-settings-dev 4.0.4.r7081.gca187b0-1
pacman 7.0.0-1
pinta 3.1.2-2
quickshell-git 0.3.0.r20.g28771c7-2
ttf-jetbrains-mono-nerd-basic 3.4.0-1
uboot-asahi 2026.07.asahi2-3
LOCAL
  for file in omarchy-dev-4.0.4.r7081.gca187b0-1-aarch64.pkg.tar.zst omarchy-settings-dev-4.0.4.r7081.gca187b0-1-aarch64.pkg.tar.zst \
    linux-aurora-7.1.12.aurora2-7-aarch64.pkg.tar.xz m1n1-aurora-1.6.1.aurora1-2-aarch64.pkg.tar.xz; do
    echo cached >"$R/var/cache/pacman/pkg/$file"
  done
  repo core <<<"pacman 7.0.0-1"
  printf 'hyprland 0.51-1\nlimine 12.9.0-1\nquickshell 0.3.1-1\n' | repo extra
  repo asahi-alarm <<<"asahi-scripts 20260127.1-1"
  printf 'hyprland 0.50-1\nlimine-mkinitcpio-hook 1.36.0-3\nmise 2026.9.4-1\nobs-studio 32.2.2-1\npinta 3.1.2-2\nuboot-asahi 2026.07.asahi2-3\n' |
    repo omarchy-fork omarchy
  printf 'linux-aurora 7.1.12.aurora2-7\nlinux-aurora-headers 7.1.12.aurora2-7\nm1n1-aurora 1.6.1.aurora1-2\n' | repo omarchy-aurora
  sign_repo omarchy-fork omarchy
  sign_repo omarchy-aurora omarchy-aurora
  repo omarchy <<'EDGE'
omarchy 4.0.2-1
omarchy-settings 4.0.2-1
omarchy-mac 0.1.0-5
omarchy-mac-boot 20260925-2
linux-aurora 7.1.12.aurora2-10
linux-aurora-headers 7.1.12.aurora2-10
m1n1-aurora 1.6.1.aurora1-3
uboot-asahi 2026.07.asahi2-4
limine-mkinitcpio-hook 1.39.0-2
mise-bin 2026.9.12-1
omarchy-keyring 20251027-1
omarchy-nvim 2026.9.21-1
pinta 3.1.2-1
ttf-jetbrains-mono-nerd-basic 3.5.1-1
EDGE
  for name in core/core extra/extra asahi-alarm/asahi-alarm; do
    cp "$F/repos/$name.db" "$R/var/lib/pacman/sync/"
  done
  fork_update
  cat >"$F/conflicts" <<'CONFLICTS'
omarchy omarchy-dev
omarchy-settings omarchy-settings-dev
quickshell quickshell-git
mise-bin mise
linux-aurora linux-asahi
m1n1-aurora m1n1
linux-aurora-headers linux-asahi-headers
CONFLICTS

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
  echo "base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck" >"$F/hooks"
  printf '%s\n' "$R/boot/efi" >"$F/mounts"
  echo /dev/mapper/root >"$F/root-source"
  printf '/dev/mapper/root crypt btrfs\n/dev/nvme0n1p6 part crypto_LUKS\n/dev/nvme0n1 disk \n' >"$F/lsblk"
  : >"$F/pacman.log"
  : >"$F/boot.log"
}

migrate() {
  OMARCHY_MAC_MIGRATE_ROOT=$R MIGRATE_FIXTURE=$F PATH="$stubs:$PATH" "$R/usr/bin/omarchy-mac-migrate" "$@"
}

killed_run() { # variable step command
  env "OMARCHY_MAC_MIGRATE_KILL_$1=$2" OMARCHY_MAC_MIGRATE_ROOT="$R" MIGRATE_FIXTURE="$F" PATH="$stubs:$PATH" \
    "$R/usr/bin/omarchy-mac-migrate" "$3"
}

reboot_into_aurora() {
  echo boot-2 >"$R/proc/sys/kernel/random/boot_id"
  echo 7.1.12-aurora >"$R/proc/sys/kernel/osrelease"
}

state_dir() {
  printf '%s\n' "$R/var/lib/omarchy-mac/migration"
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
}

fixture_digest() {
  (cd "$R" && find . -path ./var/tmp -prune -o -path ./run/lock -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum
}

finish() {
  local output
  output=$(migrate run 2>&1) || fail "the resumed migration runs to its reboot" "$output"
  if [[ ! -f $(state_dir)/complete ]]; then
    reboot_into_aurora
    output=$(migrate verify 2>&1) || fail "the migration finishes after its reboot" "$output"
  fi
  [[ -f $(state_dir)/complete ]] || fail "the migration completes" "$(cat "$(state_dir)/journal")"
}

# --- The whole transition --------------------------------------------------

new_fixture baseline
luks_before=$(cat "$R/etc/crypttab" "$R/etc/default/limine" "$R/boot/efi/limine.conf")
output=$(migrate run 2>&1) || fail "an mx-mac Mac migrates to its reboot" "$output"
grep -q "Reboot to finish the migration to candidate-set apple-test-fixture" <<<"$output" || fail "the run asks for a reboot" "$output"
state=$(state_dir)
[[ $(cat "$state/plan/cohort") == "mx-mac" ]] || fail "the Mac is planned as mx-mac" "$(cat "$state/plan/cohort")"
pass "an mx-mac Mac is planned by its own adapter and migrated up to its reboot"

expected_packages='hyprland 0.51-1
limine 12.9.0-1
limine-mkinitcpio-hook 1.39.0-2
linux-aurora 7.1.12.aurora2-10
linux-aurora-headers 7.1.12.aurora2-10
m1n1-aurora 1.6.1.aurora1-3
mise-bin 2026.9.12-1
obs-studio 32.2.2-1
omarchy 4.0.0.alpha.quattro.r1.gabc-1.1
omarchy-keyring 20251027-1
omarchy-mac 0.1.0-5.1
omarchy-mac-boot 20260926-1.43
omarchy-nvim 2026.9.21-1
omarchy-settings 4.0.0.alpha.quattro.r1.gabc-1.1
pacman 7.0.0-1
pinta 3.1.2-1.1
quickshell 0.3.1-1
ttf-jetbrains-mono-nerd-basic 3.5.1-1
uboot-asahi 2026.07.asahi2-4'
[[ $(cat "$R/var/lib/pacman/local/packages") == "$expected_packages" ]] ||
  fail "one transaction swaps the dev pair and the bundle for official builds and moves Aurora to the target" "$(cat "$R/var/lib/pacman/local/packages")"
grep -qx "transaction omarchy-mac-candidate/omarchy omarchy-mac-candidate/omarchy-settings omarchy-mac-candidate/omarchy-mac omarchy-mac-candidate/omarchy-mac-boot omarchy-mac-candidate/linux-aurora omarchy-mac-candidate/linux-aurora-headers omarchy-mac-candidate/m1n1-aurora omarchy-mac-candidate/uboot-asahi omarchy-mac-candidate/limine-mkinitcpio-hook omarchy-mac-candidate/pinta hyprland mise-bin omarchy-keyring omarchy-nvim quickshell ttf-jetbrains-mono-nerd-basic" "$F/pacman.log" ||
  fail "the target's packages the Mac has come from the target, and each other fork build an official repository carries is named" "$(grep transaction "$F/pacman.log")"
[[ $(grep -c '^transaction ' "$F/pacman.log") == 1 ]] || fail "one package transaction"
[[ $(cat "$state/plan/allowed-removals") == $'mise\nomarchy-dev\nomarchy-settings-dev\nquickshell-git' ]] ||
  fail "only the fork builds official ones of another name replace may be removed" "$(cat "$state/plan/allowed-removals")"
grep -qx "obs-studio 32.2.2-1" "$state/plan/kept" || fail "a fork build with no official one is kept and listed" "$(cat "$state/plan/kept")"
! grep -q "^avd-fw " "$R/var/lib/pacman/local/packages" || fail "a target package the Mac never had is not installed"
pass "one transaction replaces omarchy-dev, its settings and the bundle, downgrades a higher fork build, keeps what has no official build and adds no package the Mac lacks"

conf=$(sed "s|$F|FIXTURE|g" "$R/etc/pacman.conf")
[[ $conf == "[options]
HoldPkg = pacman glibc
Architecture = aarch64
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

# Aurora kernel and bootloader, kept on the qualified release by omarchy update
[omarchy]
Server = file://FIXTURE/repos/omarchy

[asahi-alarm]
SigLevel = Required DatabaseOptional
Server = file://FIXTURE/repos/asahi-alarm

[core]
Server = file://FIXTURE/repos/core

[extra]
Server = file://FIXTURE/repos/extra" ]] || fail "the switch drops both fork sections and puts the official [omarchy] first" "$conf"
[[ ! -e $R/var/lib/pacman/sync/omarchy-aurora.db && ! -e $R/var/lib/pacman/sync/omarchy-aurora.db.sig ]] || fail "the fork's Aurora database is gone"
[[ ! -e $R/var/lib/pacman/sync/omarchy.db.sig ]] && cmp -s "$F/repos/omarchy/omarchy.db" "$R/var/lib/pacman/sync/omarchy.db" ||
  fail "the official [omarchy] database replaces the fork's, without the fork's signature beside it"
! grep -q "^$fork_key \|^$release_key " "$R/etc/pacman.d/gnupg/keys" || fail "the fork's package and release keys are deleted" "$(cat "$R/etc/pacman.d/gnupg/keys")"
grep -q "^$official f" "$R/etc/pacman.d/gnupg/keys" && ! grep -q "$signer" "$R/etc/pacman.d/gnupg/keys" ||
  fail "the Omarchy key stays trusted and the candidate key never enters pacman's keyring"
pass "no fork repository, signature or key is left, and the official database is the one pacman reads"

! grep -q "update-grub\|limine-boot activate" "$F/boot.log" || fail "a Limine Mac is not switched again" "$(cat "$F/boot.log")"
[[ $(grep -E '^(update-m1n1|omarchy-mac-limine-cmdline|limine-update|omarchy-mac-limine-deploy)' "$F/boot.log" | tr '\n' '|') == \
  "update-m1n1 |omarchy-mac-limine-cmdline |limine-update|omarchy-mac-limine-deploy|" ]] ||
  fail "m1n1 and the UKI are rebuilt and checked before the packaged Limine is deployed" "$(cat "$F/boot.log")"
[[ $(cat "$R/etc/crypttab" "$R/etc/default/limine" "$R/boot/efi/limine.conf") == "$luks_before" && -e $R/var/lib/omarchy/limine.enabled ]] ||
  fail "the unlock settings, the Limine defaults and its menu are unchanged"
grep -q "^cryptsetup luksHeaderBackup /dev/nvme0n1p6 " "$F/pacman.log" && [[ -f $state/backup/luks-header.img ]] ||
  fail "the LUKS header of the root partition is backed up"
tar -xOf "$state/backup/etc.tar" etc/pacman.conf | grep -q '^\[omarchy-aurora\]' || fail "the backup holds the fork's pacman.conf"
pass "encryption and Limine are kept: the UKI is rebuilt, the packaged loader deployed, the LUKS header backed up"

reboot_into_aurora
output=$(migrate verify 2>&1) || fail "the post-reboot verification completes the migration" "$output"
grep -q "Kept, with no official build: obs-studio" <<<"$output" || fail "completion names what was kept" "$output"
for name in asahi-quattro-release asahi-quattro-release.pending asahi-package-repository aurora-target.descriptor apple-silicon-channel apple-silicon-aurora-lane; do
  [[ ! -e $R/var/lib/omarchy/$name && -f $state/backup/mx-mac-state/$name ]] || fail "the fork updaters' $name is moved into the backup"
done
[[ $(stat -c %a "$state/backup/mx-mac-state") == 700 ]] || fail "the retired state is readable by root only"
[[ -e $R/var/lib/omarchy/mac-first-boot/install.conf ]] || fail "state no fork updater owns stays"
[[ $(migrate status) == *"State: complete"* ]] || fail "status reports completion"
baseline=$(outcome)
pass "after the reboot, the bundle and channel updaters' state is retired into the backup"

output=$(migrate run 2>&1) || fail "a second run succeeds" "$output"
grep -q "Already migrated to candidate-set apple-test-fixture" <<<"$output" && [[ $(outcome) == "$baseline" ]] ||
  fail "a second run changes nothing" "$output"
pass "the migration is idempotent"

# --- Interruption at every journal step ---------------------------------------

interrupt() { # when step
  local when=$1 step=$2 status=0 output last transactions=1 recorded
  new_fixture "kill-$when-$step"
  output=$(killed_run "${when^^}" "$step" run 2>&1) || status=$?
  if (( status == 0 )); then
    reboot_into_aurora
    output=$(killed_run "${when^^}" "$step" verify 2>&1) || status=$?
  fi
  (( status == 137 )) || fail "the run is killed $when $step" "status $status: $output"
  recorded=${step#mx-mac-}
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
}

for step in "${steps[@]}"; do
  interrupt after "$step"
done
pass "a kill -9 between any two journal steps resumes to the same end, with one transaction"
for step in "${steps[@]}"; do
  interrupt during "$step"
done
pass "a kill -9 after any step's work but before its record resumes to the same end"
for step in backup keyring prefetch repositories transaction boot-chain loader reboot mx-mac-retire retire; do
  interrupt mid "$step"
done
pass "a kill -9 in the middle of any step, the adapter's retire included, resumes to the same end"

# --- The fork moving under a migration -----------------------------------------

# The fork's omarchy update runs before the migration resumes: its channel
# updaters put the fork sections, databases and key back, and its bundle
# updater moves the runtime pair.
for step in repositories keyring; do
  new_fixture "fork-update-$step"
  killed_run AFTER "$step" run >/dev/null 2>&1 && fail "the run is killed after $step"
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
killed_run AFTER repositories run >/dev/null 2>&1 && fail "the run is killed after the switch"
fork_pacman_conf >"$R/etc/pacman.conf"
finish
grep -q " prefetch reset pacman.conf or a retired key came back after the repository switch" "$(state_dir)/journal" || fail "a rewritten pacman.conf alone is noticed" "$(cat "$(state_dir)/journal")"
[[ $(outcome) == "$baseline" ]] || fail "a rewritten pacman.conf is switched again" "$(diff <(echo "$baseline") <(outcome))"
pass "a channel updater's rewrite of pacman.conf after the switch is switched back before the transaction"

new_fixture key-only
killed_run AFTER repositories run >/dev/null 2>&1 && fail "the run is killed after the switch"
echo "$release_key f" >>"$R/etc/pacman.d/gnupg/keys"
finish
grep -q " prefetch reset pacman.conf or a retired key came back after the repository switch" "$(state_dir)/journal" ||
  fail "a fork key trusted again alone is noticed" "$(cat "$(state_dir)/journal")"
[[ $(outcome) == "$baseline" ]] || fail "a fork key trusted again is deleted again" "$(diff <(echo "$baseline") <(outcome))"
pass "a fork key trusted again after the switch is deleted again before the transaction"

# --- Refusals and failures -------------------------------------------------------

refused() { # description reason-pattern
  local status=0 output digest
  digest=$(fixture_digest)
  output=$(migrate run 2>&1) || status=$?
  (( status == 2 )) || fail "$1: preflight refuses" "status $status: $output"
  grep -q -- "$2" <<<"$output" || fail "$1: the refusal says why" "$output"
  [[ ! -e $(state_dir) ]] || fail "$1: no migration state is created"
  [[ $(fixture_digest) == "$digest" ]] || fail "$1: nothing on the system changed"
  ! grep -q '^transaction\|^pacman-key' "$F/pacman.log" || fail "$1: no transaction or key change ran"
}

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
echo "Usage: omarchy-apple-silicon-boot-check [linux-aurora|linux-asahi]" >"$F/boot-check-fail"
refused "the fork's own boot tools" "cannot read the initramfs HOOKS"
new_fixture refusals
head -c 16 /dev/urandom >>"$F/set/$(jq -r '.packages[0].filename' "$F/set/manifest.json")"
refused "a tampered candidate package" "does not verify: omarchy-.* is missing or changed"
new_fixture refusals
printf 'format=1\ntype=repository\nchannel=stable\nserver=file://%s/repos/omarchy\n' "$F" >"$R/etc/omarchy-mac/migration-target"
sed -i '/^omarchy-mac /d' "$F/repos/omarchy/omarchy.db"
refused "a target without omarchy-mac" "does not resolve on this Mac"
new_fixture no-pair
printf 'format=1\ntype=repository\nchannel=stable\nserver=file://%s/repos/omarchy\npackages=omarchy omarchy-mac omarchy-mac-boot linux-aurora\n' "$F" >"$R/etc/omarchy-mac/migration-target"
digest=$(fixture_digest)
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "the target has no omarchy and omarchy-settings" <<<"$output" && [[ ! -e $(state_dir) && $(fixture_digest) == "$digest" ]] ||
  fail "a target without the runtime pair stops the plan and changes nothing" "status $status: $output"
pass "preflight refuses legacy unlock, untrusted repositories, an unfinished first boot, the fork's boot tools and an incomplete or unverifiable target, changing nothing"

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
(( status == 1 )) && grep -q "would also remove obs-studio; nothing was changed" <<<"$output" || fail "an unexpected removal stops the rehearsal" "$output"
[[ $(cat "$R/etc/pacman.conf") == "$conf_before" && $(cat "$R/var/lib/pacman/local/packages") == "$packages_before" ]] ||
  fail "the fork's repositories and packages are untouched after a failed rehearsal"
pass "a rehearsal that would remove a kept fork build fails before the switch"

# --- Other mx-mac Macs -------------------------------------------------------------

new_fixture grub
rm "$R/var/lib/omarchy/limine.enabled" "$R/etc/default/limine" "$R/boot/efi/limine.conf" "$R/boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
echo grub >"$R/boot/efi/EFI/BOOT/BOOTAA64.EFI"
cat >"$R/usr/lib/omarchy-mac/boot/setup/limine-boot.sh" <<'LEAF'
echo "limine-boot activate OMARCHY_PATH=$OMARCHY_PATH" >>"$MIGRATE_FIXTURE/boot.log"
printf 'KERNEL_CMDLINE[default]="root=UUID=x"\n' >"$OMARCHY_MAC_MIGRATE_ROOT/etc/default/limine"
limine-update
cp "$OMARCHY_MAC_MIGRATE_ROOT/usr/share/limine/BOOTAA64.EFI" "$OMARCHY_MAC_MIGRATE_ROOT/boot/efi/EFI/BOOT/BOOTAA64.EFI"
LEAF
finish
grep -q "^limine-boot activate" "$F/boot.log" && [[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" ]] ||
  fail "an mx-mac Mac on GRUB is switched to Limine" "$(cat "$F/boot.log")"
pass "an mx-mac Mac that still boots GRUB is switched to Limine"

new_fixture repository
printf 'format=1\ntype=repository\nchannel=stable\nserver=file://%s/repos/omarchy\n' "$F" >"$R/etc/omarchy-mac/migration-target"
finish
grep -qx "transaction omarchy/omarchy omarchy/omarchy-settings omarchy/omarchy-mac omarchy/omarchy-mac-boot omarchy/linux-aurora omarchy/linux-aurora-headers omarchy/m1n1-aurora omarchy/uboot-asahi omarchy/limine-mkinitcpio-hook hyprland mise-bin omarchy-keyring omarchy-nvim pinta quickshell ttf-jetbrains-mono-nerd-basic" "$F/pacman.log" ||
  fail "a repository target names the Mac packages in the official [omarchy], not the fork's" "$(grep transaction "$F/pacman.log")"
grep -q "^omarchy 4.0.2-1$" "$R/var/lib/pacman/local/packages" && ! grep -q "^omarchy-dev " "$R/var/lib/pacman/local/packages" ||
  fail "the official runtime replaces the fork's" "$(cat "$R/var/lib/pacman/local/packages")"
pass "a repository target, whose [omarchy] has the fork section's name, replaces the fork's builds"
