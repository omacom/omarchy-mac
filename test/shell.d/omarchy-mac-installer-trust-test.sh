#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
checkout="$ROOT"
new_key=FBD6874D423C418DDB6D143EECE19CDDE306DBD2
old_key=F3C5AE3FCFFC738C301E30A8F0C548C0D27279F7
# Extract just the production helper and its pin; never run the installer.
eval "$(sed -n '/^readonly omarchy_mac_key=/p' "$ROOT/install.sh")"
eval "$(sed -n '/^ensure_omarchy_mac_keyring() {$/,/^}$/p' "$ROOT/install.sh")"
[[ $omarchy_mac_key == "$new_key" ]] || fail 'installer pins the wrong primary'
log() { :; }
sudo() {
  printf '%s\n' "$*" >>"$test_tmp/calls"
  case "$*" in
    "pacman-key --list-keys $new_key") [[ $has_new == 1 ]] ;;
    "pacman-key --add $checkout/default/pacman/keyrings/omarchy-mac.gpg")
      [[ ${reject_import:-0} == 0 ]] || return 1
      has_new=1 ;;
    "pacman-key --finger $new_key")
      [[ $has_new == 1 ]] || return 1
      printf '%s\n' "${returned_key:-$new_key}" ;;
    "pacman-key --lsign-key $new_key") [[ $has_new == 1 ]] ;;
    *) return 99 ;;
  esac
}
for state in fresh old-only new-only both; do
  has_new=0
  [[ $state != new-only && $state != both ]] || has_new=1
  expected_imports=$((1-has_new))
  : >"$test_tmp/calls"
  ensure_omarchy_mac_keyring
  [[ $(grep -c -- '--add ' "$test_tmp/calls" || true) == "$expected_imports" ]] || fail "$state import count"
  grep -qxF "pacman-key --lsign-key $new_key" "$test_tmp/calls" || fail "$state missing new trust"
  if grep -qF "$old_key" "$test_tmp/calls"; then fail "$state requested old key"; fi
done
has_new=0
if (reject_import=1; ensure_omarchy_mac_keyring) >/dev/null 2>&1; then fail 'failed import accepted'; fi
has_new=1
if (returned_key="$old_key"; ensure_omarchy_mac_keyring) >/dev/null 2>&1; then fail 'wrong fingerprint accepted'; fi
pass 'fresh installer establishes only the new pin and rejects missing or wrong trust'
