#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export TEST_TRUST_CALLS="$test_tmp/calls" OMARCHY_PATH="$ROOT"
old_key=F3C5AE3FCFFC738C301E30A8F0C548C0D27279F7
new_key=FBD6874D423C418DDB6D143EECE19CDDE306DBD2
export TEST_OLD_KEY="$old_key" TEST_NEW_KEY="$new_key"

# Migration queue coverage lives in the migration and successor suites.
source "$ROOT/install/helpers/arm-channel.sh"
omarchy_arm_channel_key_fingerprints() { printf '%s\n' "${fixture_keys[@]}"; }
sudo() {
  printf '%s\n' "$*" >>"$TEST_TRUST_CALLS"
  if [[ $1 == gpg && $4 == --batch && $5 == --list-keys ]]; then
    printf '%s\n' "${fixture_keys[@]}" | grep -qxF "$6"
  elif [[ $1 == pacman-key && $4 == --add ]]; then
    [[ $5 == "$ROOT/default/pacman/keyrings/omarchy-mac.gpg" ]] || return 99
    [[ ${TEST_INCOMPLETE_CERT:-0} == 1 ]] || fixture_keys+=("$new_key")
    return 0
  elif [[ $1 == pacman-key && $4 == --lsign-key ]]; then
    [[ $5 == "$new_key" ]]
  else
    return 99
  fi
}
for state in fresh old-only new-only both; do
  fixture_keys=()
  case "$state" in
    old-only) fixture_keys=("$old_key") ;;
    new-only) fixture_keys=("$new_key") ;;
    both) fixture_keys=("$old_key" "$new_key") ;;
  esac
  : >"$TEST_TRUST_CALLS"
  omarchy_arm_channel_trust_fork "$test_tmp/private-keyring"
  if grep -qxF "pacman-key --gpgdir $test_tmp/private-keyring --lsign-key $old_key" "$TEST_TRUST_CALLS"; then fail "$state authorized old trust"; fi
  grep -qxF "pacman-key --gpgdir $test_tmp/private-keyring --lsign-key $new_key" "$TEST_TRUST_CALLS" || fail "$state did not establish new trust"
  expected=1
  [[ $state != both && $state != new-only ]] || expected=0
  [[ $(grep -c -- '--add ' "$TEST_TRUST_CALLS" || true) == "$expected" ]] || fail "$state certificate import count differs"
done
fixture_keys=()
if TEST_INCOMPLETE_CERT=1 omarchy_arm_channel_trust_fork "$test_tmp/private-keyring"; then
  fail 'fresh trust accepts a certificate missing the replacement primary'
fi
pass 'fresh and channel trust stages require the new primary for fresh and old-only clients'

[[ $(cat "$ROOT/default/pacman/keyrings/omarchy-mac-trusted") == "$new_key:4:" ]] || fail 'packaged trusted primaries differ from transition pins'
(
  source "$ROOT/build-inputs/omarchy-mac-keyring/PKGBUILD"
  [[ $pkgver == 20260914 && $pkgrel == 2 ]]
  for index in "${!source[@]}"; do
    [[ $(sha512sum "$ROOT/default/pacman/keyrings/${source[$index]}" | cut -d' ' -f1) == "${sha512sums[$index]}" ]]
  done
) || fail 'versioned package recipe must bind exact public trust files'
pass 'packaged public trust and checksums match the versioned transition'
