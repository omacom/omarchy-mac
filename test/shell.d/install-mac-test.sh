#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

install_script="$ROOT/install.sh"
build_script="$ROOT/build-packages.sh"

[[ -x $install_script ]] || fail "the Apple Silicon installer ships and is executable"
[[ -x $build_script ]] || fail "the Apple Silicon package build script ships and is executable"
pass "the Apple Silicon install scripts ship and are executable"

# Quattro renamed the setup entry points once already, and set -e turns a call
# to a command that no longer ships into a half-finished install.
while read -r command_name; do
  [[ -n $command_name ]] || continue
  [[ -x "$ROOT/bin/$command_name" ]] ||
    fail "the installer only calls commands that ship in bin/" "missing: $command_name"
# Anchored to command position so paths and filenames the script merely names,
# like omarchy-base.packages or the omarchy-build cache directory, stay out.
done < <(grep -oE '^[[:space:]]*(sudo[[:space:]]+)?omarchy-[a-z0-9-]+' "$install_script" |
  grep -oE 'omarchy-[a-z0-9-]+' | sort -u)
pass "the installer only calls commands that ship in bin/"

grep -F 'sudo omarchy-apply-system --install-user "$USER" --first-install' "$install_script" >/dev/null ||
  fail "the installer applies system setup as root for a first install"
grep -F 'omarchy-provision-user --first-install' "$install_script" >/dev/null ||
  fail "the installer finalizes the user for a first install"
pass "the installer runs first-install system and user setup"

# useradd -m ran before omarchy-settings existed, so /etc/skel never seeded
# $HOME. Without this replay the user gets no shipped configs at all.
grep -F 'omarchy-reinstall-configs' "$install_script" >/dev/null ||
  fail "the installer seeds shipped defaults into an already-created home"
pass "the installer seeds shipped defaults into an already-created home"

# Macs boot through GRUB. Depending on limine would also make
# install/login/alt-bootloaders.sh skip the plymouth setup it guards.
for limine_package in limine limine-mkinitcpio-hook limine-snapper-sync; do
  grep -qF "  $limine_package" "$build_script" ||
    fail "the package build drops $limine_package from the Apple Silicon dependencies"
done
pass "the package build drops the limine stack from the Apple Silicon dependencies"

# The hotfix rebuild number has to land on omarchy and omarchy-settings, not
# the keyring or the font. Run in a subshell: sourcing the builder replaces
# fail() with one that exits without TAP.
rel_dir=$(mktemp -d)
printf 'pkgrel=1\n' >"$rel_dir/PKGBUILD"
if ! (
  source "$build_script"
  set_pkgrel "$rel_dir/PKGBUILD"
  [[ $(cat "$rel_dir/PKGBUILD") == "pkgrel=1" ]] || exit 1
  OMARCHY_PKGREL=2 set_pkgrel "$rel_dir/PKGBUILD"
  [[ $(cat "$rel_dir/PKGBUILD") == "pkgrel=2" ]] || exit 1
  for bad in nope 0 02 -1 1.5; do
    if ( OMARCHY_PKGREL=$bad set_pkgrel "$rel_dir/PKGBUILD" >/dev/null 2>&1 ); then
      exit 1
    fi
  done
); then
  rm -rf "$rel_dir"
  fail "set_pkgrel no-ops without OMARCHY_PKGREL, writes a number, and rejects junk"
fi
rm -rf "$rel_dir"
grep -A2 'package == "omarchy-settings"' "$build_script" | grep -q set_pkgrel ||
  fail "the package build stamps pkgrel on omarchy and omarchy-settings"
pass "the package build can stamp a Mac-only pkgrel on omarchy and omarchy-settings"

# build-output is the hand-off directory for one install attempt. Keeping an
# archive from an earlier retry makes pacman see two versions of the same
# package; detached signatures are metadata, not package archives.
grep -qF 'remove_old_packages' "$build_script" ||
  fail "the package build clears archives from an earlier retry"
grep -qF 'rm -f -- "$artifact"' "$build_script" ||
  fail "the package build removes stale package archives safely"
grep -qF '[[ -f $artifact && $artifact != *.sig ]]' "$build_script" ||
  fail "the package build does not hand detached signatures to the installer"
grep -qF '[[ -f $artifact && $artifact != *.sig ]]' "$install_script" ||
  fail "the installer does not pass detached signatures to pacman"
pass "the Apple Silicon package hand-off contains only current archives"

# Clearing the hand-off directory is only useful if main calls it before the
# package loop. Pin the ordering so a future refactor cannot leave the helper
# covered in isolation while retries still mix old and new archives.
main_body=$(awk '/^main\(\) \{/{inside=1} inside {print} inside && /^}/ {exit}' "$build_script")
remove_line=$(grep -nF '  remove_old_packages' <<<"$main_body" || true)
build_call_line=$(grep -nF '    build_package "$package"' <<<"$main_body" || true)
[[ -n $remove_line && -n $build_call_line ]] ||
  fail "the package build clears old archives before its package loop"
remove_line=${remove_line%%:*}
build_call_line=${build_call_line%%:*}
(( remove_line < build_call_line )) ||
  fail "the package build clears old archives before its package loop"
pass "the package build clears old archives before its package loop"

# The refresh runs from omarchy-reinstall-configs under set -e, so a machine
# without limine must no-op rather than abort the seeding step.
grep -F 'omarchy-cmd-missing limine' "$ROOT/bin/omarchy-refresh-limine" >/dev/null ||
  fail "refreshing limine no-ops on a machine without limine"
pass "refreshing limine no-ops on a machine without limine"

# gum arrives with the omarchy package a third of the way in, so without this
# the install looks nothing like the rest of Omarchy until its last stretch.
grep -qF 'ensure_gum' "$install_script" ||
  fail "the installer installs gum up front"
gum_call=$(grep -n '^  ensure_gum$' "$install_script" | cut -d: -f1)
set_call=$(grep -n '^  install_default_package_set$' "$install_script" | cut -d: -f1)
[[ -n $gum_call && -n $set_call ]] || fail "the installer installs gum and the package set"
(( gum_call < set_call )) || fail "gum is installed before the long package phase"
grep -qF 'gum style' "$install_script" ||
  fail "the installer speaks through gum once it is available"
pass "the installer styles its output with gum from the start"

# A generic aarch64 base has the Asahi repo stanza but not its signing keyring.
# Bootstrap and locally sign the documented master key before pacman refreshes,
# or optional ARM packages fail later with a misleading missing-database error.
grep -qF 'asahi_alarm_key=' "$install_script" ||
  fail "the installer pins the Asahi Alarm package signing key"
grep -qF 'pacman-key --recv-keys "$asahi_alarm_key" --keyserver hkps://keyserver.ubuntu.com' "$install_script" ||
  fail "the installer bootstraps the Asahi Alarm package signing key"
grep -qF 'pacman-key --lsign-key "$asahi_alarm_key"' "$install_script" ||
  fail "the installer locally trusts the Asahi Alarm package signing key"
grep -qF 'pacman -Sy --needed --noconfirm asahi-alarm-keyring' "$install_script" ||
  fail "the installer installs the Asahi Alarm package keyring"
keyring_call=$(grep -n '^  ensure_asahi_alarm_keyring$' "$install_script" | cut -d: -f1)
refresh_call=$(grep -nF '  sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu --needed --noconfirm "${targets[@]}"' "$install_script" | cut -d: -f1)
[[ -n $keyring_call && -n $refresh_call ]] || fail "the installer bootstraps the Asahi keyring before refresh"
(( keyring_call < refresh_call )) ||
  fail "the Asahi keyring is installed before the package database refresh"
pass "the installer bootstraps Asahi signing keys before refreshing ARM packages"

repo_call=$(sed -n '/^main() {/,/^}/p' "$install_script" | grep -n '^  ensure_arm_package_repo$' | cut -d: -f1)
main_line=$(grep -n '^main() {$' "$install_script" | cut -d: -f1)
repo_call=$(( main_line + repo_call - 1 ))
build_call=$(grep -n '^  build_omarchy_packages$' "$install_script" | cut -d: -f1)
[[ -n $repo_call && -n $build_call ]] || fail "the installer prepares repositories before package builds"
(( repo_call < build_call && repo_call < gum_call )) || fail "the compatible stack transaction precedes package operations"
grep -qF 'source "$checkout/install/helpers/arm-package-sources.sh"' "$install_script" || fail "the installer uses shared source policy"
pass "the installer prepares the compatible stack before package operations"

# Run the real orchestration with harmless stubs. A separate bash process
# preserves errexit even when the test captures an expected nonzero status.
setup_body=$(sed -n '/^run_system_setup() {/,/^}/p' "$install_script")
for failing_stage in none system repositories; do
  setup_status=0
  setup_output=$(SETUP_BODY="$setup_body" FAILING_STAGE="$failing_stage" bash -c '
    set -euo pipefail
    log() { :; }
    sudo() {
      [[ $* == "omarchy-apply-system --install-user $USER --first-install" ]]
      echo system
      [[ $FAILING_STAGE != "system" ]]
    }
    ensure_arm_package_repo() {
      echo repositories
      [[ $FAILING_STAGE != "repositories" ]]
    }
    omarchy-provision-user() {
      [[ $* == "--first-install" ]]
      echo user
    }
    eval "$SETUP_BODY"
    run_system_setup
  ') || setup_status=$?
  case $failing_stage in
    none) expected_output=$'system\nrepositories\nuser'; expected_status=0 ;;
    system) expected_output=system; expected_status=1 ;;
    repositories) expected_output=$'system\nrepositories'; expected_status=1 ;;
  esac
  [[ $setup_output == "$expected_output" && $setup_status == "$expected_status" ]] ||
    fail "system setup refreshes restored repositories before user setup ($failing_stage)" "$setup_output (status $setup_status)"
done
pass "system setup refreshes restored repositories before user setup and stops on failure"
