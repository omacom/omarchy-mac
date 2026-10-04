# Shared by the omarchy-mac-migrate suites (test/shell.d/mac-migrate-*-test.sh).
#
# Each case builds a fixture root (a Mac's pacman configuration, package
# database, keyring, /boot and ESP) and runs bin/omarchy-mac-migrate
# unprivileged against it, with pacman, the keyring, the boot tools, the new
# runtime's dispatcher and the device probes replaced by the stand-ins in
# test/fixtures/mac-migrate/bin. Candidate sets are signed with a disposable
# key by the real gpg; the archives preflight reads (the runtime and
# omarchy-mac-boot) are real tar files.
# shellcheck disable=SC2034

require_command gpg
require_command gpgv
require_command jq
require_command flock
require_command bsdtar

# The failure's evidence follows its description.
fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'for home in signer other subkey-home; do gpgconf --homedir "$tmp/$home" --kill gpg-agent 2>/dev/null; done; rm -rf "$tmp"' EXIT
stubs=$ROOT/test/fixtures/mac-migrate/bin
tool=$ROOT/bin/omarchy-mac-migrate
steps=(preflight backup keyring prefetch repositories transaction boot-chain loader defaults verify unpin reboot retire)
official=40DFB630FF42BCFFB047046CF0134EE680CAC571

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

# make_archive NAME VERSION FILE: a package archive pacman and bsdtar can read,
# with the files a release ships that preflight looks for. Other packages are
# noise.
make_archive() {
  local name=$1 version=$2 file=$3 dir
  dir=$(mktemp -d)
  printf 'pkgname = %s\npkgver = %s\n' "$name" "$version" >"$dir/.PKGINFO"
  case $name in
    omarchy-dev | omarchy)
      install -D -m 755 /dev/null "$dir/usr/bin/omarchy-lifecycle-dispatch"
      ;;
    omarchy-mac-boot)
      install -D -m 755 /dev/null "$dir/usr/lib/omarchy/mac-boot/setup-boot"
      install -D -m 755 /dev/null "$dir/usr/lib/omarchy/mac-boot/update-verify"
      install -D -m 755 /dev/null "$dir/usr/bin/omarchy-mac-esp"
      ;;
  esac
  if [[ $name == omarchy-dev || $name == omarchy || $name == omarchy-mac-boot ]]; then
    bsdtar -czf "$file" -C "$dir" .PKGINFO usr
  else
    head -c 512 /dev/urandom >"$file"
  fi
  rm -rf "$dir"
}

# The packages of a fixture candidate set: the edge runtime pair (or SET_PAIR)
# and the Mac set.
set_packages() {
  cat <<SET
${SET_PAIR_RUNTIME:-omarchy-dev} 4.0.0.r7000.gabc-1.1
${SET_PAIR_SETTINGS:-omarchy-settings-dev} 4.0.0.r7000.gabc-1.1
omarchy-mac 0.1.0-11.1
omarchy-mac-boot 20261004-1.1
linux-aurora 7.1.12.aurora2-11
linux-aurora-headers 7.1.12.aurora2-11
m1n1-aurora 1.6.1.aurora1-3
uboot-asahi 2026.07.asahi2-4
limine-mkinitcpio-hook 1.39.0-2
${SET_EXTRA:-}
SET
}

# The candidate set as tools/release/candidate-set signs it.
make_set() {
  local dir=$1 key_home=$2 name version file entries=()
  mkdir -p "$dir"
  while read -r name version; do
    [[ -n $name ]] || continue
    file="$name-$version-aarch64.pkg.tar.zst"
    make_archive "$name" "$version" "$dir/$file"
    entries+=("$(jq -n --arg name "$name" --arg version "$version" --arg filename "$file" --arg sha256 "$(sha256sum "$dir/$file" | cut -d' ' -f1)" \
      '{name: $name, version: $version, filename: $filename, sha256: $sha256}')")
    gpg --batch --homedir "$key_home" --detach-sign --no-armor -o "$dir/$file.sig" "$dir/$file" 2>/dev/null
  done < <(set_packages)
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

# repo DIR [NAME]: a file:// repository in $F/repos/DIR whose database is NAME.db.
repo() {
  mkdir -p "$F/repos/$1"
  cat >"$F/repos/$1/${2:-$1}.db"
}

# archive NAME VERSION: the archive a repository target's NAME downloads as.
archive() {
  mkdir -p "$F/archives"
  make_archive "$1" "$2" "$F/archives/$1"
}

# The ALARM repositories the core configuration names, empty unless given, and
# the mirror list they come from.
alarm_repos() {
  local name
  for name in core extra alarm aur; do
    [[ -f $F/repos/$name/$name.db ]] || repo "$name" </dev/null
  done
  mkdir -p "$R/etc/pacman.d"
  echo "Server = file://$F/repos/\$repo" >"$R/etc/pacman.d/mirrorlist"
}

# The relations between the fixtures' packages, as pacman resolves them.
relations() {
  printf 'linux-aurora linux-asahi\nm1n1-aurora m1n1\nlinux-aurora-headers linux-asahi-headers\nomarchy-dev omarchy\nomarchy-settings-dev omarchy-settings\n' >"$F/conflicts"
  printf 'omarchy-dev omarchy\nomarchy-settings-dev omarchy-settings\n' >"$F/provides"
}

migrate() {
  OMARCHY_MAC_MIGRATE_ROOT=$R MIGRATE_FIXTURE=$F OMARCHY_MAC_MIGRATE_ASAHI_SERVER="file://$F/repos/asahi-alarm" \
    OMARCHY_MAC_MIGRATE_SERVER="file://$F/repos/official-@channel@" PATH="$stubs:$PATH" "$tool" "$@"
}

# migrate_env VAR=VALUE... -- ARGS: migrate with extra environment.
migrate_env() {
  local extra=()
  while [[ $1 != "--" ]]; do
    extra+=("$1")
    shift
  done
  shift
  env "${extra[@]}" OMARCHY_MAC_MIGRATE_ROOT="$R" MIGRATE_FIXTURE="$F" OMARCHY_MAC_MIGRATE_ASAHI_SERVER="file://$F/repos/asahi-alarm" \
    OMARCHY_MAC_MIGRATE_SERVER="file://$F/repos/official-@channel@" PATH="$stubs:$PATH" "$tool" "$@"
}

reboot_into_aurora() {
  echo boot-2 >"$R/proc/sys/kernel/random/boot_id"
  echo 7.1.12-aurora >"$R/proc/sys/kernel/osrelease"
}

state_dir() {
  printf '%s\n' "$R/var/lib/omarchy-mac/migration"
}

# Snapshot of the fixture a refused or failed run must leave as it was.
fixture_digest() {
  (cd "$R" && find . -path ./var/tmp -prune -o -path ./run/lock -prune -o -path ./var/lib/omarchy-mac/migration/deferred -prune -o -type f -print0 |
    LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum
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

kill_after() { # step
  local output
  output=$(migrate_env OMARCHY_MAC_MIGRATE_KILL_AFTER="$1" -- run 2>&1) && fail "the run is killed after $1" "$output"
  return 0
}

# refused DESCRIPTION REASON-PATTERN: the run defers (75) with nothing changed.
refused() {
  local status=0 output digest
  digest=$(fixture_digest)
  output=$(migrate run 2>&1) || status=$?
  (( status == 75 )) || fail "$1: preflight refuses" "status $status: $output"
  grep -q -- "$2" <<<"$output" || fail "$1: the refusal says why" "$output"
  [[ ! -e $(state_dir)/journal ]] || fail "$1: no migration is started"
  [[ $(fixture_digest) == "$digest" ]] || fail "$1: nothing on the system changed"
  ! grep -q '^transaction\|^pacman-key' "$F/pacman.log" || fail "$1: no transaction or change to the live keyring ran"
}
