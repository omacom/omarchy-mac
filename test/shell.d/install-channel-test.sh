#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
source "$ROOT/test/shell.d/helpers/install-orchestration.sh"
run_case --channel rc || fail 'published RC orchestration'
[[ $(cat "$CALLS") == $'preconditions\nprepare rc fresh\nlocale\napply\nenvironment\nprotect\ntrust\ngum\naur\ndefaults\nseed\nsetup\nunprotect\nsnapshot\ncleanup' ]] || fail 'published preflight precedes mutations and never builds different bytes'
pass 'explicit RC installs the preflighted pair and bypasses local builds'
FAIL_AT='prepare rc fresh' run_case --channel rc && fail 'failed preflight must stop'
[[ $(cat "$CALLS") == $'preconditions\nprepare rc fresh\ncleanup' ]] || fail 'failed preflight leaves locale and package state untouched'
pass 'missing or invalid lane stops before system mutation'
FAIL_AT=apply run_case --channel stable && fail 'failed captured transaction must stop'
[[ $(cat "$CALLS") == $'preconditions\nprepare stable fresh\nlocale\napply\ncleanup' ]] || fail 'failed captured transaction skips subsequent setup'
PAIR_VERSION=4.0.3rc2-1 run_case --channel rc && fail 'pair changed by default phase must fail'
! grep -q '^setup$' "$CALLS" || fail 'changed pair aborts before setup/snapshot'
pass 'transaction failure or pair drift cannot report completed install'
run_case || fail 'legacy source install'
grep -q '^build$' "$CALLS" || fail 'legacy installer still builds checkout'
! grep -q '^prepare' "$CALLS" || fail 'legacy installer does not switch to an unavailable stable lane'
CHANNEL=edge run_case || fail 'environment lane selection'
grep -qx 'prepare edge fresh' "$CALLS" || fail 'OMARCHY_MIRROR lane interface'
run_case --channel bogus && fail 'invalid lane must fail'
[[ ! -s $CALLS ]] || fail 'invalid option must not reach preconditions'
pass 'legacy source build and explicit environment lane contracts remain distinct'
setup_output=$(FUNCTIONS="$work/functions" bash -euo pipefail -c '
  source "$FUNCTIONS"
  install_channel=rc USER=fixture
  log() { :; }
  sudo() {
    [[ $* == "env OMARCHY_MIRROR=rc OMARCHY_PRESERVE_PACMAN_CONFIG=1 omarchy-apply-system --install-user fixture --first-install" ]]
    echo system
  }
  ensure_arm_package_repo() { echo unexpected-refresh; exit 1; }
  omarchy-provision-user() { [[ $* == "--first-install" ]]; echo user; }
  run_system_setup
') || fail 'published setup environment propagation'
[[ $setup_output == $'system\nuser' ]] || fail 'published setup preserves candidate config without a second system transaction'
pass 'published system setup preserves the staged lane and package-pair protection'
