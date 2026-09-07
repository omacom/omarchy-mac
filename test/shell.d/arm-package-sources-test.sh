#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/install/helpers/arm-package-sources.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
sudo() {
  if [[ $1 == "pacman-key" ]]; then
    printf '%s\n' "$*" >> "$test_tmp/keys"
  else
    "$@"
  fi
}

printf '%s\n' '[options]' 'Architecture = aarch64' '[extra]' 'Server = https://regular.example/$arch' '[omarchy]' 'Usage = All' 'SigLevel = Never' 'Server = https://old.example/$arch' '[omarchy-aarch64]' 'Server = https://mac.example' > "$test_tmp/pacman.conf"
omarchy_arm_prepare_package_sources "$test_tmp/pacman.conf"
grep -q '^Server = https://regular.example/\$arch$' "$test_tmp/pacman.conf" || fail 'regular mirror preserved'
grep -q '^Server = https://mac.example$' "$test_tmp/pacman.conf" || fail 'Mac repository preserved'
! grep -q 'Usage = All\|SigLevel = Never\|old.example' "$test_tmp/pacman.conf" || fail 'unrestricted old edge section removed'
[[ $(grep -c '^\[omarchy\]$' "$test_tmp/pacman.conf") == "1" ]] || fail 'single edge section'
grep -q '^Usage = Sync$' "$test_tmp/pacman.conf" || fail 'edge selection restricted'
grep -q '^SigLevel = Required DatabaseOptional$' "$test_tmp/pacman.conf" || fail 'signed packages required'
cp "$test_tmp/pacman.conf" "$test_tmp/expected"
omarchy_arm_prepare_package_sources "$test_tmp/pacman.conf"
cmp -s "$test_tmp/expected" "$test_tmp/pacman.conf" || fail 'preparation idempotent'
pass 'source preparation preserves regular repositories and restricts edge idempotently'

cp "$test_tmp/pacman.conf.bak" "$test_tmp/original-backup"
cp "$ROOT/default/pacman/pacman-stable.conf" "$test_tmp/pacman.conf"
omarchy_arm_prepare_package_sources "$test_tmp/pacman.conf" preserve-backup
cmp -s "$test_tmp/original-backup" "$test_tmp/pacman.conf.bak" || fail 'channel refresh original backup preserved'
pass 'preparation after channel replacement preserves the original backup'

mapfile -t targets < <(omarchy_arm_package_targets)
[[ ${targets[*]} == "omarchy/hyprland omarchy/hyprtoolkit omarchy/hyprland-guiutils" ]] || fail 'only approved packages selected'
pass 'Aquamarine remains a regular-repository dependency'

# Exercise the real default-package loop after the compatibility transaction.
# The three selected packages must never reach yay as unqualified targets.
eval "$(sed -n '/^install_default_package_set() {/,/^seed_user_defaults() {/p' "$ROOT/install.sh" | sed '$d')"
checkout=$ROOT
log() { :; }
warn() { :; }
load_unavailable_packages() { :; }
should_attempt_unavailable() { return 1; }
package_is_unavailable_here() { return 1; }
pacman() { [[ $1 == "-Q" ]] && printf '%s\n' "$2" >> "$test_tmp/checked"; }
yay() { printf '%s\n' "$*" >> "$test_tmp/yay"; }
install_default_package_set
for package in hyprland hyprtoolkit hyprland-guiutils; do
  if grep -qxF "$package" "$ROOT/install/omarchy-base.packages"; then
    grep -qxF "$package" "$test_tmp/checked" || fail "$package availability checked"
  fi
  ! grep -qE "(^| )$package( |$)" "$test_tmp/yay" || fail "$package must not be downgraded by yay"
done
grep -q 'wf-recorder' "$test_tmp/yay" || fail 'regular package path still runs'
pass 'default package loop preserves the compatibility transaction selection'

for config in "$ROOT"/default/pacman/pacman*.conf; do
  section=$(sed -n '/^\[omarchy\]$/,/^$/p' "$config")
  [[ $section == *"Usage = Sync"* && $section == *"SigLevel = Required DatabaseOptional"* ]] || fail "restricted signed edge in $config"
done
pass 'all shipped channels preserve restricted signed edge'
