#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

# Explicit opt-in: this builds a package and initializes disposable GPG trust.
if [[ ${OMARCHY_RUN_NATIVE_KEYRING_TEST:-0} != 1 ]]; then
  printf 'ok - native keyring package install # SKIP set OMARCHY_RUN_NATIVE_KEYRING_TEST=1\n'
  exit 0
fi
for tool in bwrap makepkg pacman gpg gpgconf findmnt; do require_command "$tool"; done
scratch_parent=${OMARCHY_TEST_TMPDIR:-${TMPDIR:-/var/tmp}}
case $(findmnt -n -o FSTYPE -T "$scratch_parent") in
  ''|tmpfs|ramfs) fail 'native keyring test requires disk-backed scratch' ;;
esac
work=$(mktemp -d "$scratch_parent/keyring-package-install-XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export TMPDIR="$work/tmp" TMP="$work/tmp" TEMP="$work/tmp"
mkdir -p "$work"/{tmp,build,root/etc/pacman.d,root/var/lib/pacman,root/var/cache/pacman/pkg,root/usr/share/pacman/keyrings,root/home,root/dev}
cp "$ROOT/build-inputs/omarchy-mac-keyring/"* "$work/build/"
cp "$ROOT/default/pacman/keyrings/"* "$work/build/"
# Build through the real recipe, including its source checksum validation.
(cd "$work/build" && makepkg --nodeps --nosign --nocheck >"$work/build.log" 2>&1) || {
  cat "$work/build.log" >&2; fail 'keyring package builds';
}
packages=("$work/build/"*.pkg.tar.*)
[[ ${#packages[@]} == 1 ]] || fail 'exactly one keyring package was built'
cp "${packages[0]}" "$work/keyring.pkg.tar.zst"
# Exact public-only quattro fixture works in shallow checkouts and source archives.
baseline="$ROOT/test/fixtures/omarchy-mac-keyring-20260913-1"
(cd "$baseline" && sha256sum --check SHA256SUMS) || fail 'previous public fixture checksums'
mkdir "$work/build-previous"
for name in PKGBUILD omarchy-mac-keyring.install omarchy-mac.gpg omarchy-mac-trusted omarchy-mac-revoked; do
  cp "$baseline/$name" "$work/build-previous/$name"
done
(cd "$work/build-previous" && makepkg --nodeps --nosign --nocheck >"$work/build-previous.log" 2>&1) || {
  cat "$work/build-previous.log" >&2; fail 'previous committed keyring package builds';
}
previous_packages=("$work/build-previous/"*.pkg.tar.*)
[[ ${#previous_packages[@]} == 1 ]] || fail 'exactly one previous keyring package was built'
cp "${previous_packages[0]}" "$work/previous.pkg.tar.zst"
cat >"$work/root/etc/pacman.conf" <<'CONF'
[options]
Architecture = auto
SigLevel = Never
LocalFileSigLevel = Never
CONF
cat >"$work/check.sh" <<'INNER'
set -euo pipefail
export HOME=/home TMPDIR=/tmp TMP=/tmp TEMP=/tmp
key=FBD6874D423C418DDB6D143EECE19CDDE306DBD2
# The hook must install payload gracefully before pacman trust is initialized.
pacman -U --noconfirm /work/keyring.pkg.tar.zst >/work/uninitialized.log 2>&1
grep -q 'Initialize pacman-key' /work/uninitialized.log
[[ ! -e /etc/pacman.d/gnupg/trustdb.gpg ]]
pacman -R --noconfirm omarchy-mac-keyring >/work/remove-uninitialized.log 2>&1
printf 'ok - package hook leaves uninitialized pacman trust untouched and explains recovery\n'
pacman-key --init >/work/init.log 2>&1
mkdir -m700 /work/unrelated
# Disposable independent trust must survive installation and upgrade.
gpg --homedir /work/unrelated --batch --passphrase '' --quick-generate-key 'Independent fixture' ed25519 cert 1d >/work/unrelated.log 2>&1
other=$(gpg --homedir /work/unrelated --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
gpg --homedir /work/unrelated --export "$other" >/work/unrelated.gpg
add_unrelated() {
  pacman-key --add /work/unrelated.gpg >"$1" 2>&1
  pacman-key --lsign-key "$other" >>"$1" 2>&1
}
add_unrelated /work/add.log
trusted() {
  gpg --homedir /etc/pacman.d/gnupg --batch --with-colons --list-keys "$1" 2>/dev/null |
    awk -F: '$1=="pub" && ($2=="f" || $2=="u") {ok=1} END {exit !ok}'
}
trusted "$other"
pacman -U --noconfirm /work/keyring.pkg.tar.zst >/work/install.log 2>&1
for name in omarchy-mac.gpg omarchy-mac-trusted omarchy-mac-revoked; do
  cmp "/usr/share/pacman/keyrings/$name" "/work/build/$name"
done
trusted "$key"
trusted "$other"
printf 'ok - actual package post_install establishes new trust and preserves unrelated trust\n'
# Start the upgrade scenario with independent initialized trust. Removing a
# keyring package does not delete keys it previously populated, so reusing the
# fresh-install keyring would manufacture the shipped baseline incorrectly.
pacman -R --noconfirm omarchy-mac-keyring >/work/remove-fresh.log 2>&1
gpgconf --homedir /etc/pacman.d/gnupg --kill all
rm -rf /etc/pacman.d/gnupg
pacman-key --init >/work/reinit.log 2>&1
add_unrelated /work/readd.log
trusted "$other"
if gpg --homedir /etc/pacman.d/gnupg --list-keys "$key" >/dev/null 2>&1; then exit 1; fi
pacman -U --noconfirm /work/previous.pkg.tar.zst >/work/previous.log 2>&1
[[ $(pacman -Q omarchy-mac-keyring) == 'omarchy-mac-keyring 20260913-1' ]]
previous_key=F3C5AE3FCFFC738C301E30A8F0C548C0D27279F7
trusted "$previous_key"
# The shipped predecessor contains only the old primary; the upgrade must add the new one.
if gpg --homedir /etc/pacman.d/gnupg --list-keys "$key" >/dev/null 2>&1; then exit 1; fi
pacman -U --noconfirm /work/keyring.pkg.tar.zst >/work/upgrade.log 2>&1
[[ $(pacman -Q omarchy-mac-keyring) == 'omarchy-mac-keyring 20260914-2' ]]
grep -q 'upgrading omarchy-mac-keyring' /work/upgrade.log
trusted "$previous_key"
trusted "$key"
trusted "$other"
printf 'ok - actual shipped 20260913-1 to 20260914-2 upgrade adds new trust and preserves old and unrelated trust\n'
INNER
# No host home, /etc, /var, device tree, network, or sockets are exposed.
# All writable paths including /tmp live under verified disk-backed scratch.
bwrap --unshare-all --die-with-parent --new-session --uid 0 --gid 0 \
  --bind "$work/root" / --ro-bind /usr/bin /usr/bin --ro-bind /usr/lib /usr/lib \
  --ro-bind /usr/share/makepkg /usr/share/makepkg \
  --symlink usr/bin /bin --symlink usr/bin /sbin --symlink usr/lib /lib \
  --dev-bind /dev/null /dev/null --dev-bind /dev/random /dev/random --dev-bind /dev/urandom /dev/urandom \
  --bind "$work" /work --bind "$work/tmp" /tmp --proc /proc \
  /bin/bash /work/check.sh || {
    for log in "$work"/*.log; do printf '%s\n' "${log##*/}" >&2; tail -20 "$log" >&2; done
    fail 'isolated real package install/upgrade trust validation';
  }
