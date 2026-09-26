#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-mac-migrate moves a quattro-upstream tester Mac onto a signed target
# set. Each case stages the package into a fixture root (the tester's pacman
# configuration, package database, keyring, /boot and ESP) and runs the staged
# command unprivileged, with pacman, the keyring, the boot tools and the
# device probes replaced by the stand-ins in fixtures/migrate/bin. Candidate
# sets are signed with a disposable key by the real gpg.
require_command gpg
require_command gpgv
require_command jq
require_command flock

# The failure's evidence follows its description.
fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'for home in signer other subkey-home; do gpgconf --homedir "$tmp/$home" --kill gpg-agent 2>/dev/null; done; rm -rf "$tmp"' EXIT
stubs=$ROOT/test/fixtures/migrate/bin
steps=(preflight backup keyring prefetch repositories transaction boot-chain loader defaults reboot retire)
official=40DFB630FF42BCFFB047046CF0134EE680CAC571
retired=FBD6874D423C418DDB6D143EECE19CDDE306DBD2

make_key() {
  mkdir -m 700 "$tmp/$1"
  gpg --batch --homedir "$tmp/$1" --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Migration test $1" ed25519 sign 1d 2>/dev/null
  gpg --batch --homedir "$tmp/$1" --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
}
signer=$(make_key signer)
other=$(make_key other)
gpg --batch --homedir "$tmp/signer" --armor --export "$signer" >"$tmp/signer.asc" 2>/dev/null
gpg --batch --homedir "$tmp/other" --armor --export "$other" >"$tmp/other.asc" 2>/dev/null

# The candidate set as tools/release/candidate-set signs it.
make_set() {
  local dir=$1 key_home=$2 name version file entries=()
  mkdir -p "$dir"
  while read -r name version; do
    file="$name-$version-aarch64.pkg.tar.zst"
    head -c 512 /dev/urandom >"$dir/$file"
    entries+=("$(jq -n --arg name "$name" --arg version "$version" --arg filename "$file" --arg sha256 "$(sha256sum "$dir/$file" | cut -d' ' -f1)" \
      '{name: $name, version: $version, filename: $filename, sha256: $sha256}')")
    gpg --batch --homedir "$key_home" --detach-sign --no-armor -o "$dir/$file.sig" "$dir/$file" 2>/dev/null
  done <<'SET'
omarchy 4.0.0.alpha.quattro.r1.gabc-1.1
omarchy-settings 4.0.0.alpha.quattro.r1.gabc-1.1
omarchy-mac 0.1.0-5.1
omarchy-mac-boot 20260925-2.1
linux-aurora 7.1.12.aurora2-10
linux-aurora-headers 7.1.12.aurora2-10
m1n1-aurora 1.6.1.aurora1-3
uboot-asahi 2026.07.asahi2-4
limine-mkinitcpio-hook 1.39.0-2
SET
  printf '%s\n' "${entries[@]}" | jq -s '{schema: 1, set: "apple-test-fixture", packages: .}' >"$dir/manifest.json.new"
  jq --arg digest "$(jq -r '.packages[] | "\(.name) \(.version) \(.filename) \(.sha256)"' "$dir/manifest.json.new" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)" \
    '.set_sha256 = $digest' "$dir/manifest.json.new" >"$dir/manifest.json"
  rm "$dir/manifest.json.new"
  resign_set "$dir" "$key_home"
}

resign_set() {
  local dir=$1 key_home=$2 fpr
  fpr=$(gpg --batch --homedir "$key_home" --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  jq -n --slurpfile manifest "$dir/manifest.json" --arg fpr "$fpr" --arg sha "$(sha256sum "$dir/manifest.json" | cut -d' ' -f1)" \
    '{schema: 1, manifest_sha256: $sha, set_sha256: $manifest[0].set_sha256, signer: {fingerprint: $fpr},
      signatures: [$manifest[0].packages[] | {file: .filename}]}' >"$dir/signing.json"
  rm -f "$dir/signing.json.sig"
  gpg --batch --homedir "$key_home" --detach-sign --no-armor -o "$dir/signing.json.sig" "$dir/signing.json" 2>/dev/null
  gpg --batch --homedir "$key_home" --armor --export "$fpr" >"$dir/candidate-signing-key.asc" 2>/dev/null
}

make_set "$tmp/set" "$tmp/signer"

repo() {
  mkdir -p "$F/repos/$1"
  cat >"$F/repos/$1/$1.db"
}

# A GRUB tester on the Asahi kernel with an encrypted root: runtime and
# settings 4.0.2-2 and a newer cursor-bin from the unsigned collaboration
# repository, omarchy-mac above the candidate's release.
new_fixture() {
  local name=$1
  F=$tmp/$name
  R=$F/root
  rm -rf "$F"
  mkdir -p "$R"
  bash "$ROOT/install" "$R"
  cat >"$R/usr/lib/omarchy-mac/boot/setup/limine-boot.sh" <<'LEAF'
# Stands in for the package's Limine activation leaf.
if [[ -e $MIGRATE_FIXTURE/limine-activation-fail ]]; then
  echo "limine-boot: limine-update failed; activation failed" >&2
  exit 1
fi
echo "limine-boot activate OMARCHY_PATH=$OMARCHY_PATH" >>"$MIGRATE_FIXTURE/boot.log"
printf 'KERNEL_CMDLINE[default]="root=UUID=x"\n' >"$OMARCHY_MAC_MIGRATE_ROOT/etc/default/limine"
# Killed half way through the switch, before the UKI exists.
if [[ ${OMARCHY_MAC_MIGRATE_KILL_MID:-} == "loader-leaf" && ! -e $MIGRATE_FIXTURE/killed-in-leaf ]]; then
  : >"$MIGRATE_FIXTURE/killed-in-leaf"
  kill -9 $$ $BASHPID
fi
limine-update
cp "$OMARCHY_MAC_MIGRATE_ROOT/usr/share/limine/BOOTAA64.EFI" "$OMARCHY_MAC_MIGRATE_ROOT/boot/efi/EFI/BOOT/BOOTAA64.EFI"
LEAF
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
  printf 'linux-asahi 6.19.1-1\nm1n1 1.5.0-1\nuboot-asahi 2026.01-1\n' | repo asahi-alarm
  printf 'omarchy 4.0.2-1\nomarchy-settings 4.0.2-1\ncursor-bin 3.20.10-1\n' | repo omarchy-old
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
cursor-bin 3.20.10-1
EDGE
  printf 'omarchy 4.0.2-2\nomarchy-settings 4.0.2-2\ncursor-bin 3.20.17-1\nwidget-extra 1.0-1\n' | repo omarchy-aarch64
  cp "$F/repos/omarchy-aarch64/omarchy-aarch64.db" "$R/var/lib/pacman/sync/"
  printf 'linux-aurora linux-asahi\nm1n1-aurora m1n1\nlinux-aurora-headers linux-asahi-headers\n' >"$F/conflicts"

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
Server = file://$F/repos/core

[extra]
Server = file://$F/repos/extra

[omarchy]
SigLevel = Optional TrustAll
Server = file://$F/repos/omarchy-old

[omarchy-aarch64]
SigLevel = Optional TrustAll
Server = file://$F/repos/omarchy-aarch64
CONF
  cp -r "$tmp/set" "$F/set"
  cat >"$R/etc/omarchy-mac/migration-target" <<TARGET
# The signed candidate set, with omacom edge for everything else.
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

migrate() {
  OMARCHY_MAC_MIGRATE_ROOT=$R MIGRATE_FIXTURE=$F PATH="$stubs:$PATH" "$R/usr/bin/omarchy-mac-migrate" "$@"
}

reboot_into_aurora() {
  echo boot-2 >"$R/proc/sys/kernel/random/boot_id"
  echo 7.1.12-aurora >"$R/proc/sys/kernel/osrelease"
}

state_dir() {
  printf '%s\n' "$R/var/lib/omarchy-mac/migration"
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
}

# Snapshot of the fixture a refused or failed run must leave as it was.
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
output=$(migrate run 2>&1) || fail "a tester migrates to its reboot" "$output"
grep -q "Reboot to finish the migration to candidate-set apple-test-fixture" <<<"$output" || fail "the run asks for a reboot" "$output"
[[ $(migrate status) == *"State: waiting for a reboot"* ]] || fail "status reports the pending reboot" "$(migrate status)"
grep -q "^systemctl enable omarchy-mac-migrate-verify.service" "$F/boot.log" || fail "the post-reboot check is enabled"
output=$(migrate verify 2>&1) || fail "verify before the reboot waits" "$output"
[[ ! -f $(state_dir)/complete ]] || fail "nothing completes before the reboot"
pass "a GRUB tester is migrated up to its reboot, which it waits for"

state=$(state_dir)
expected_packages='cursor-bin 3.20.10-1
hyprland 0.51-1
limine 12.9.0-1
limine-mkinitcpio-hook 1.39.0-2
linux-aurora 7.1.12.aurora2-10
m1n1-aurora 1.6.1.aurora1-3
omarchy 4.0.0.alpha.quattro.r1.gabc-1.1
omarchy-mac 0.1.0-5.1
omarchy-mac-boot 20260925-2.1
omarchy-settings 4.0.0.alpha.quattro.r1.gabc-1.1
pacman 7.0.0-1
uboot-asahi 2026.07.asahi2-4
widget-extra 1.0-1'
[[ $(cat "$R/var/lib/pacman/local/packages") == "$expected_packages" ]] ||
  fail "the transaction replaces every same-name candidate, even higher ones, and swaps the Asahi kernel and m1n1" "$(cat "$R/var/lib/pacman/local/packages")"
grep -q "^transaction omarchy-mac-candidate/omarchy omarchy-mac-candidate/omarchy-settings omarchy-mac-candidate/omarchy-mac " "$F/pacman.log" ||
  fail "targets are named in the candidate repository" "$(grep transaction "$F/pacman.log")"
grep -q "^transaction .* cursor-bin$" "$F/pacman.log" || fail "a collaboration build the official repositories carry is named too"
! grep -q "headers" "$F/pacman.log" || fail "no kernel headers are installed where there were none"
[[ $(grep -c '^transaction ' "$F/pacman.log") == 1 ]] || fail "one package transaction"
grep -q "^widget-extra 1.0-1$" "$state/plan/kept" || fail "a build with no official counterpart is kept and listed"
pass "one transaction replaces same-name candidates, including higher-versioned ones, and keeps what has no official build"

conf=$(sed "s|$F|FIXTURE|g" "$R/etc/pacman.conf")
[[ $conf == "[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

# Arch Linux ARM and Asahi
[omarchy]
Server = file://FIXTURE/repos/omarchy

[asahi-alarm]
Server = file://FIXTURE/repos/asahi-alarm

[core]
Server = file://FIXTURE/repos/core

[extra]
Server = file://FIXTURE/repos/extra" ]] || fail "the switch puts [omarchy] first and removes the collaboration repository and every TrustAll" "$conf"
! grep -q candidate "$R/etc/pacman.conf" || fail "the candidate repository never enters pacman.conf"
[[ ! -e $R/var/lib/pacman/sync/omarchy-aarch64.db && ! -e $R/var/lib/pacman/sync/omarchy-mac-candidate.db ]] ||
  fail "the retired and candidate databases are gone"
grep -q "^pacman-key --populate archlinuxarm asahi-alarm omarchy" "$F/pacman.log" || fail "the installed keyrings are populated"
grep -q "^pacman-key --recv-keys $official" "$F/pacman.log" && grep -q "^$official f" "$R/etc/pacman.d/gnupg/keys" ||
  fail "the missing Omarchy key is fetched by fingerprint and trusted"
! grep -q "^$retired " "$R/etc/pacman.d/gnupg/keys" || fail "the retired fork key is deleted"
! grep -q "$signer" "$R/etc/pacman.d/gnupg/keys" || fail "the candidate key never enters pacman's keyring"
pass "official precedence, official trust bootstrapped by fingerprint, legacy trust and candidates gone"

for file in installed etc.tar boot.tar esp.tar luks-header.img packages/omarchy-4.0.2-2-aarch64.pkg.tar.xz \
  packages/linux-asahi-6.19.1-1-aarch64.pkg.tar.zst packages/m1n1-1.5.0-1-aarch64.pkg.tar.zst SHA256SUMS; do
  [[ -f $state/backup/$file ]] || fail "the backup holds $file"
done
grep -q "^omarchy-mac 0.1.0-5.9$" "$state/backup/packages.missing" || fail "an uncached package is listed as missing from the backup"
(cd "$state/backup" && sha256sum -c --quiet SHA256SUMS) || fail "the backup's digests verify"
[[ $(stat -c %a "$state/backup") == 700 ]] || fail "the backup is readable by root only"
tar -tf "$state/backup/esp.tar" | grep -q 'EFI/BOOT/BOOTAA64.EFI' || fail "the ESP backup holds the loader"
grep -q "^cryptsetup luksHeaderBackup /dev/nvme0n1p5 " "$F/pacman.log" || fail "the LUKS header of the root partition is backed up"
tar -xOf "$state/backup/esp.tar" ./EFI/BOOT/BOOTAA64.EFI | grep -qx grub || fail "the ESP backup predates the switch"
pass "packages, /etc, /boot, the ESP and the LUKS header are backed up before anything changes"

[[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" && -e $R/var/lib/omarchy/limine.enabled ]] ||
  fail "Limine takes the loader slot"
grep -q "^limine-boot activate OMARCHY_PATH=/usr/share/omarchy" "$F/boot.log" || fail "a GRUB Mac is switched by the package's activation"
[[ $(grep -n '' "$F/boot.log" | grep -E 'update-m1n1|update-grub|boot-check pending --boot-chain linux-aurora|limine-boot' | cut -d: -f2- | head -n 4 | tr '\n' '|') == \
  "update-m1n1 |update-grub |boot-check pending --boot-chain linux-aurora|limine-boot activate OMARCHY_PATH=/usr/share/omarchy|" ]] ||
  fail "m1n1, the DTBs and U-Boot are rebuilt and checked before Limine takes the slot" "$(cat "$F/boot.log")"
pass "the boot chain is rebuilt and checked before Limine replaces GRUB"

reboot_into_aurora
output=$(migrate verify 2>&1) || fail "the post-reboot verification completes the migration" "$output"
[[ -f $state/complete && ! -e $state/reboot-pending && ! -e $state/cache ]] || fail "completion retires the working state"
grep -q "^boot-check --boot-chain linux-aurora$" "$F/boot.log" || fail "the booted chain passes the boot check"
grep -q "^systemctl disable omarchy-mac-migrate-verify.service" "$F/boot.log" || fail "the post-reboot check is disabled again"
[[ ! -e $R/var/lib/omarchy/migrations/omarchy-aarch64-sync-pending ]] || fail "the collaboration repository's marker is retired"
[[ $(migrate status) == *"State: complete"* ]] || fail "status reports completion"
baseline=$(outcome)
pass "after the reboot, Aurora through Limine is verified and compatibility state is retired"

output=$(migrate run 2>&1) || fail "a second run succeeds" "$output"
grep -q "Already migrated to candidate-set apple-test-fixture" <<<"$output" || fail "a second run says it is done" "$output"
[[ $(outcome) == "$baseline" ]] || fail "a second run changes nothing"
rm -rf "$state"
output=$(migrate run 2>&1) || fail "a Mac already on the target set passes" "$output"
grep -q "already runs the target set" <<<"$output" && [[ ! -e $state ]] || fail "a Mac already on the target set is left alone" "$output"
pass "the migration is idempotent"

# --- Interruption at every journal step ---------------------------------------

interrupt() { # when step
  local when=$1 step=$2 status=0 output last transactions=1
  new_fixture "kill-$when-$step"
  output=$(env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$step" OMARCHY_MAC_MIGRATE_ROOT="$R" MIGRATE_FIXTURE="$F" PATH="$stubs:$PATH" \
    "$R/usr/bin/omarchy-mac-migrate" run 2>&1) || status=$?
  if (( status == 0 )); then
    reboot_into_aurora
    output=$(env "OMARCHY_MAC_MIGRATE_KILL_${when^^}=$step" OMARCHY_MAC_MIGRATE_ROOT="$R" MIGRATE_FIXTURE="$F" PATH="$stubs:$PATH" \
      "$R/usr/bin/omarchy-mac-migrate" verify 2>&1) || status=$?
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
for step in backup keyring prefetch repositories transaction boot-chain loader loader-leaf defaults reboot retire; do
  interrupt mid "$step"
done
pass "a kill -9 in the middle of any step resumes to the same end; pacman killed before its hooks runs the transaction again"

# --- Preflight refusals ---------------------------------------------------------

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
sed -i '/^omarchy /d' "$R/var/lib/pacman/local/packages"
refused "Omarchy 3.x" "upgrade the 3.x install with omarchy-upgrade-to-quattro-mac first"
new_fixture refusals
echo "base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems fsck" >"$F/hooks"
refused "busybox encrypt" "busybox encrypt"
new_fixture refusals
printf '\n[custom]\nSigLevel = Optional TrustAll\nServer = file:///custom\n' >>"$R/etc/pacman.conf"
refused "an unknown TrustAll repository" "\[custom\] accepts untrusted packages"
new_fixture refusals
sed -i 's/^SigLevel = Required DatabaseOptional$/SigLevel = Optional TrustAll/' "$R/etc/pacman.conf"
refused "a weak global SigLevel" "global SigLevel accepts unsigned"
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
# A key file that also carries the pinned key passes its fingerprint check;
# each signature must still be the pinned key's.
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
mkdir -p "$F/usr-bin"
for command in /usr/bin/*; do
  [[ ${command##*/} == "gpgv" ]] || ln -s "$command" "$F/usr-bin/"
done
digest=$(fixture_digest)
status=0
output=$(OMARCHY_MAC_MIGRATE_ROOT=$R MIGRATE_FIXTURE=$F PATH="$stubs:$F/usr-bin" "$R/usr/bin/omarchy-mac-migrate" run 2>&1) || status=$?
(( status == 2 )) && grep -q "gpgv is not installed" <<<"$output" && [[ ! -e $(state_dir) && $(fixture_digest) == "$digest" ]] ||
  fail "without gpgv a candidate set is refused, and says why" "status $status: $output"
new_fixture refusals
jq '.packages |= map(select(.name != "uboot-asahi"))' "$F/set/manifest.json" >"$F/manifest" && mv "$F/manifest" "$F/set/manifest.json"
refused "a changed manifest" "signing.json does not bind this manifest"
pass "preflight refuses unsupported cohorts, legacy unlock, untrusted repositories, busy or incoherent systems, low power or space and unverifiable sets, changing nothing"

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
echo apple-silicon >"$F/platform"
rm "$R/etc/omarchy-mac/migration-target"
output=$(migrate run 2>&1) || fail "no target is a no-op" "$output"
grep -q "No migration target is set" <<<"$output" && [[ ! -e $(state_dir) ]] || fail "without a target nothing runs" "$output"
if OMARCHY_MAC_MIGRATE_ROOT="" "$R/usr/bin/omarchy-mac-migrate" run 2>/dev/null; then fail "a normal user without a fixture root is refused"; fi
pass "other platforms, an unset target and unprivileged callers change nothing"

new_fixture target-trust
chmod 666 "$R/etc/omarchy-mac/migration-target"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "refusing the target" <<<"$output" || fail "a target others can write is refused" "$output"
chmod 644 "$R/etc/omarchy-mac/migration-target"
chmod 777 "$F/set"
output=$(migrate run 2>&1) && fail "a candidate directory others can write is refused" "$output"
pass "target files and candidate sets must be writable by their owner only"

# --- Failures after preflight --------------------------------------------------

new_fixture removal
echo "omarchy-mac-boot widget-extra" >>"$F/conflicts"
conf_before=$(cat "$R/etc/pacman.conf")
packages_before=$(cat "$R/var/lib/pacman/local/packages")
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "would also remove widget-extra; nothing was changed" <<<"$output" || fail "an unexpected removal stops the rehearsal" "$output"
[[ $(cat "$R/etc/pacman.conf") == "$conf_before" && $(cat "$R/var/lib/pacman/local/packages") == "$packages_before" ]] ||
  fail "the repositories and packages are untouched after a failed rehearsal"
[[ $(migrate status) == *"failed at prefetch: the transaction would also remove widget-extra"* ]] || fail "status names the failed step" "$(migrate status)"
pass "a rehearsal that would remove more than the plan allows fails before the switch"

new_fixture loader
: >"$F/limine-activation-fail"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "Limine could not be activated; GRUB is still the loader" <<<"$output" || fail "a failed Limine stage fails the step" "$output"
[[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "grub" && ! -e $R/var/lib/omarchy/limine.enabled ]] || fail "a failed stage leaves GRUB as the loader"
rm "$F/limine-activation-fail"
finish
[[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" ]] || fail "the retried loader step activates Limine"
pass "a failed Limine stage leaves GRUB active, and the retry finishes"

new_fixture aborted-boot
output=$(migrate run 2>&1) || fail "the migration reaches its reboot" "$output"
echo boot-2 >"$R/proc/sys/kernel/random/boot_id"
status=0
output=$(migrate verify 2>&1) || status=$?
(( status == 1 )) && grep -q "this boot runs 6.19.1-asahi, not linux-aurora 7.1.12-aurora" <<<"$output" || fail "a boot of the old kernel fails verification" "$output"
[[ ! -f $(state_dir)/complete && -e $(state_dir)/reboot-pending ]] || fail "an unverified boot retires nothing"
pass "a reboot that did not come up on Aurora is not accepted"

new_fixture busy
output=$(env OMARCHY_MAC_MIGRATE_KILL_AFTER=backup OMARCHY_MAC_MIGRATE_ROOT="$R" MIGRATE_FIXTURE="$F" PATH="$stubs:$PATH" \
  "$R/usr/bin/omarchy-mac-migrate" run 2>&1) && fail "the run is killed after its backup"
printf 'format=1\ntype=repository\nchannel=stable\nserver=file://%s/repos/omarchy\n' "$F" >"$F/stable-target"
output=$(migrate run --target "$F/stable-target" 2>&1) && fail "another target is refused while one is in progress" "$output"
grep -q "a migration to candidate-set apple-test-fixture .* is in progress" <<<"$output" || fail "the refusal names the migration in progress" "$output"
pass "a migration in progress keeps its target"

new_fixture first-boot
: >"$F/scriptlet-arms-first-boot"
finish
[[ ! -e $R/var/lib/omarchy/mac-first-boot/pending ]] || fail "a first-boot marker armed by the transaction is removed"
pass "fresh-image first boot is never armed on an existing Mac"

# --- The system moving under a migration --------------------------------------

kill_after() { # step
  local output
  output=$(env OMARCHY_MAC_MIGRATE_KILL_AFTER="$1" OMARCHY_MAC_MIGRATE_ROOT="$R" MIGRATE_FIXTURE="$F" PATH="$stubs:$PATH" \
    "$R/usr/bin/omarchy-mac-migrate" run 2>&1) && fail "the run is killed after $1" "$output"
  return 0
}

# omarchy update runs pacman -Syu before the migration resumes.
for step in prefetch repositories; do
  new_fixture "moved-$step"
  kill_after "$step"
  printf 'hyprland 0.52-1\nlimine 12.9.0-1\n' >"$F/repos/extra/extra.db"
  sed -i 's/^hyprland .*/hyprland 0.52-1/' "$R/var/lib/pacman/local/packages"
  finish
  grep -q "^hyprland 0.52-1$" "$R/var/lib/pacman/local/packages" || fail "after $step, the upgrade in between is kept"
  grep -q " prefetch reset " "$(state_dir)/journal" || fail "after $step, the changed system is rehearsed again" "$(cat "$(state_dir)/journal")"
  [[ $(grep -c '^transaction ' "$F/pacman.log") == 1 ]] || fail "after $step, one transaction"
done
pass "an update between the rehearsal and the transaction sends the migration back to rehearse, instead of sticking"

new_fixture snapshot
kill_after keyring
echo "widget-conflict 1.0-1" >>"$R/var/lib/pacman/local/packages"
echo "omarchy-mac-boot widget-conflict" >>"$F/conflicts"
sed -i '/^widget-extra /d' "$R/var/lib/pacman/local/packages"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "would also remove widget-conflict; nothing was changed" <<<"$output" ||
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
output=$(env OMARCHY_MAC_MIGRATE_KILL_MID=transaction OMARCHY_MAC_MIGRATE_ROOT="$R" MIGRATE_FIXTURE="$F" PATH="$stubs:$PATH" \
  "$R/usr/bin/omarchy-mac-migrate" run 2>&1) && fail "pacman is killed after its database write"
echo "late-extra 1.0-1" >>"$R/var/lib/pacman/local/packages"
finish
grep -q " prefetch reset " "$(state_dir)/journal" || fail "the changed packages are rehearsed again"
[[ $(grep -c '^transaction ' "$F/pacman.log") == 2 && $(grep '^transaction \|^hooks' "$F/pacman.log" | tail -n 1) == "hooks" ]] ||
  fail "a transaction killed before its hooks runs again after a new rehearsal" "$(cat "$F/pacman.log")"
pass "the transaction uses the rehearsed databases, and a killed one runs again even after a new rehearsal"

new_fixture frozen-set
kill_after preflight
head -c 16 /dev/urandom >>"$F/set/$(jq -r '.packages[0].filename' "$F/set/manifest.json")"
finish
mv "$F/set" "$F/set.gone"
output=$(migrate status) && [[ $output == *"State: complete"* ]] || fail "status needs no candidate set"
new_fixture set-gone
output=$(migrate run 2>&1) || fail "the migration reaches its reboot" "$output"
rm -rf "$F/set"
reboot_into_aurora
output=$(migrate verify 2>&1) || fail "the post-reboot verification needs no candidate set" "$output"
[[ -f $(state_dir)/complete && ! -e $(state_dir)/set ]] || fail "the verified copy is retired with the migration"
pass "after preflight only the verified copy of the set is used, and the original may change or go"

new_fixture enable
: >"$F/systemctl-fail"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "cannot enable omarchy-mac-migrate-verify.service" <<<"$output" || fail "a post-reboot check that cannot be enabled fails the run" "$output"
rm "$F/systemctl-fail"
output=$(migrate run 2>&1) || fail "the retry reaches the reboot" "$output"
[[ $(grep -c "^systemctl enable omarchy-mac-migrate-verify.service" "$F/boot.log") == 2 ]] || fail "each run enables the check again"
pass "the post-reboot check is enabled on every run, and a failure to enable it is not ignored"

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
output=$(env OMARCHY_MAC_MIGRATE_KILL_MID=defaults OMARCHY_MAC_MIGRATE_ROOT="$R" MIGRATE_FIXTURE="$F" PATH="$stubs:$PATH" \
  "$R/usr/bin/omarchy-mac-migrate" run 2>&1) && fail "the run is killed in the middle of its defaults"
grep -q "Installing the default packages a fresh install has: avd-fw libva-v4l2_request-avd" <<<"$output" || fail "the missing Apple defaults are named" "$output"
grep -q "No repository carries these default packages, so they stay missing: .*vulkan-asahi" <<<"$output" ||
  fail "defaults no repository carries are named, not fatal" "$output"
finish
[[ $(grep -c '^transaction avd-fw libva-v4l2_request-avd$' "$F/pacman.log") == 1 ]] ||
  fail "the missing Apple defaults are installed once, across a resumed step" "$(cat "$F/pacman.log")"
grep -q "^avd-fw 0.1-1$" "$R/var/lib/pacman/local/packages" && grep -q "^libva-v4l2_request-avd 1.0-1$" "$R/var/lib/pacman/local/packages" ||
  fail "the Apple defaults end installed" "$(cat "$R/var/lib/pacman/local/packages")"
! grep -q "obs-studio\|zram-generator" <(grep '^transaction' "$F/pacman.log") || fail "the base list's applications and installed defaults are left alone"
grep -q "^omarchy-mac-setup-system" "$F/boot.log" || fail "the Mac services a fresh install enables are set up"
[[ $(grep -E '^(limine-boot activate|boot-check pending --boot-chain linux-aurora|omarchy-mac-setup-system)' "$F/boot.log" | cut -d' ' -f1-2 | tr '\n' '|') == \
  "boot-check pending|limine-boot activate|boot-check pending|boot-check pending|omarchy-mac-setup-system |" ]] ||
  fail "the boot files are checked again after the default packages' hooks" "$(cat "$F/boot.log")"
[[ $(grep -n '' "$F/boot.log" | grep -E 'omarchy-mac-setup-system|systemctl enable omarchy-mac-migrate-verify' | cut -d: -f2- | head -n 2 | cut -d' ' -f1-2 | tr '\n' '|') == \
  "omarchy-mac-setup-system |systemctl enable|" ]] || fail "the defaults come before the reboot" "$(cat "$F/boot.log")"
wants=$home/.config/systemd/user/graphical-session.target.wants
for unit in omarchy-brightness-keyboard-auto.service omarchy-crash-watch.service; do
  [[ $(readlink "$wants/$unit") == "/usr/lib/systemd/user/$unit" ]] || fail "a unit new to this Mac is enabled as first run does: $unit" "$(ls -la "$wants")"
done
[[ ! -e $wants/omarchy-sleep-lock.service && ! -L $wants/omarchy-sleep-lock.service ]] || fail "a unit the Mac had and the user turned off stays off"
[[ $(readlink "$home/.config/systemd/user/omarchy-fcitx5.service") == /dev/null && ! -L $wants/omarchy-fcitx5.service ]] || fail "a masked unit stays masked"
[[ $(readlink "$wants/bt-agent.service") == /usr/lib/systemd/user/bt-agent.service ]] || fail "an enabled unit is left as it is"
[[ ! -e $R/home/guest/.config ]] || fail "an account Omarchy never ran for is left alone"
[[ $(grep -c "^omarchy-mac-setup-user HOME=$home$" "$F/boot.log") -ge 1 ]] && ! grep -q "HOME=$R/home/guest\|HOME=$R/root" "$F/boot.log" ||
  fail "the Mac user setup runs for each Omarchy user only" "$(grep setup-user "$F/boot.log")"
pass "a migrated Mac gains the Apple defaults, the Mac services and the user units a fresh install has, keeping every choice made"

new_fixture defaults-failing
echo "avd-fw 0.1-1" >>"$F/repos/asahi-alarm/asahi-alarm.db"
: >"$F/omarchy-mac-setup-system-fail"
status=0
output=$(migrate run 2>&1) || status=$?
(( status == 1 )) && grep -q "omarchy-mac-setup-system could not set up the Mac's services" <<<"$output" || fail "a failed system setup fails the step" "$output"
[[ $(migrate status) == *"failed at defaults"* ]] || fail "status names the failed defaults" "$(migrate status)"
! grep -q "^systemctl enable omarchy-mac-migrate-verify" "$F/boot.log" || fail "the reboot waits for the defaults"
rm "$F/omarchy-mac-setup-system-fail"
finish
[[ $(grep -c '^transaction avd-fw$' "$F/pacman.log") == 1 ]] || fail "the retry installs nothing twice" "$(cat "$F/pacman.log")"
pass "a failed defaults step stops before the reboot and is retried"

first_run_units=$(sed -n '/systemctl --user enable --now/,/[^\\]$/p' "$ROOT/../../../install/user/first-run/enable-user-units.sh" | grep -o '[a-z0-9-]*\.service' | xargs)
engine_units=$(sed -n 's/^fresh_user_units="\(.*\)"$/\1/p' "$ROOT/lib/migrate-engine.sh")
[[ -n $first_run_units && $first_run_units == "$engine_units" ]] ||
  fail "the migration enables the user units first run enables" "first run: $first_run_units; migration: $engine_units"
pass "the migration's user units are first run's"

# --- A tester already on Aurora and Limine ------------------------------------

# The converged image's state (the M2 Max): Aurora, m1n1-aurora, Limine in the
# slot and candidate builds, but [omarchy] listed last and an unencrypted root.
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
grep -q "^linux-aurora 7.1.12.aurora2-10$" "$R/var/lib/pacman/local/packages" || fail "the Aurora kernel moves to the target's build"
grep -q "^omarchy-mac-limine-cmdline" "$F/boot.log" && grep -q "^limine-update" "$F/boot.log" && grep -q "^omarchy-mac-limine-deploy" "$F/boot.log" ||
  fail "a Limine Mac rebuilds its menu and UKI, then deploys the packaged Limine" "$(cat "$F/boot.log")"
! grep -q "update-grub\|limine-boot activate" "$F/boot.log" || fail "a Limine Mac is not switched again" "$(cat "$F/boot.log")"
[[ $(cat "$R/boot/efi/EFI/BOOT/BOOTAA64.EFI") == "limine 12.9" ]] || fail "the slot holds the packaged Limine"
[[ ! -e $(state_dir)/backup/luks-header.img ]] && ! grep -q cryptsetup "$F/pacman.log" || fail "an unencrypted root has no header to back up"
pass "a Limine tester on an unencrypted root keeps Limine, rebuilds its UKI and deploys the packaged loader"

# --- The official repository as the target ----------------------------------------

new_fixture repository
printf 'format=1\ntype=repository\nchannel=stable\nserver=file://%s/repos/omarchy\n' "$F" >"$R/etc/omarchy-mac/migration-target"
finish
grep -q "^omarchy 4.0.2-1$" "$R/var/lib/pacman/local/packages" && grep -q "^omarchy-mac 0.1.0-5$" "$R/var/lib/pacman/local/packages" ||
  fail "the official builds replace higher-versioned tester builds" "$(cat "$R/var/lib/pacman/local/packages")"
grep -q "^transaction omarchy/omarchy omarchy/omarchy-settings omarchy/omarchy-mac omarchy/omarchy-mac-boot omarchy/linux-aurora omarchy/m1n1-aurora omarchy/uboot-asahi omarchy/limine-mkinitcpio-hook cursor-bin$" "$F/pacman.log" ||
  fail "each official package is named in [omarchy], uboot-asahi included" "$(grep transaction "$F/pacman.log")"
pass "a repository target (omacom stable later) replaces the same names from [omarchy]"

# --- Packaging and dispatch ---------------------------------------------------------

[[ -x $R/usr/lib/omarchy/mac-boot/migrate && $(stat -c %a "$R/usr/lib/omarchy/mac-boot/migrate") == 755 ]] ||
  fail "the migrate entrypoint is staged for omarchy-lifecycle-dispatch"
[[ -f $R/usr/lib/systemd/system/omarchy-mac-migrate-verify.service ]] || fail "the post-reboot unit is staged"
for file in migrate-engine.sh migrate-tester.sh migrate-legacy.sh migrate-mx-mac.sh; do
  [[ -f $R/usr/lib/omarchy-mac/boot/$file ]] || fail "$file is staged"
done
new_fixture entrypoint
output=$(OMARCHY_MAC_MIGRATE_ROOT=$R MIGRATE_FIXTURE=$F PATH="$stubs:$PATH" "$R/usr/lib/omarchy/mac-boot/migrate" 2>&1) ||
  fail "the dispatch entrypoint runs the migration" "$output"
grep -q "Reboot to finish" <<<"$output" || fail "the entrypoint runs omarchy-mac-migrate run" "$output"
pass "the package ships the dispatch entrypoint, the engine and the post-reboot unit"
