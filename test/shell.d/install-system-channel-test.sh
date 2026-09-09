#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/install/helpers/arm-package-sources.sh"
eval "$(sed -n '/^run_system_setup() {/,/^}/p' "$ROOT/install.sh")"
eval "$(declare -f omarchy_arm_package_channel | sed '1s/omarchy_arm_package_channel/real_package_channel/')"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
checkout="$ROOT"
OMARCHY_PATH="$ROOT"
config="$work/pacman.conf"
log() { :; }
omarchy_arm_package_channel() { real_package_channel "$config"; }
omarchy_arm_validate_channel() {
  [[ $2 == "$ROOT" ]] || fail "validation must use the selected checkout"
  printf 'validate:%s\n' "$1" >> "$work/calls"
  [[ ${REJECT:-0} == "0" ]]
}
sudo() {
  [[ $1 == "env" && $2 == OMARCHY_MIRROR=* && $3 == "omarchy-apply-system" ]] || fail "system setup must pass channel through sudo env"
  local OMARCHY_MIRROR=${2#*=}
  printf 'apply:%s\n' "$OMARCHY_MIRROR" >> "$work/calls"
  # Execute the production restoration statement against the private fixture.
  cp() { command cp "$2" "$config"; }
  eval "$(sed -n '/^cp -f .*pacman-/p' "$ROOT/install/post-install/pacman.sh")"
  unset -f cp
}
ensure_arm_package_repo() {
  local channel
  channel=$(real_package_channel "$config") || return
  omarchy_arm_validate_channel "$channel" "$checkout"
  printf 'revalidated:%s\n' "$channel" >> "$work/calls"
}
omarchy-provision-user() { printf 'user\n' >> "$work/calls"; }
for channel in stable rc edge; do
  command cp "$ROOT/default/pacman/pacman-$channel.conf" "$config"
  : > "$work/calls"
  run_system_setup
  expected=$(printf 'validate:%s\napply:%s\nvalidate:%s\nrevalidated:%s\nuser' "$channel" "$channel" "$channel" "$channel")
  [[ $(cat "$work/calls") == "$expected" ]] || fail "system setup lost $channel or ran before validation"
done
printf '[options]\n[core]\nServer = https://base.example\n' > "$config"
: > "$work/calls"
if run_system_setup 2>/dev/null; then fail "unknown channel must fail before setup"; fi
[[ ! -s $work/calls ]] || fail "unknown channel ran setup"
command cp "$ROOT/default/pacman/pacman-rc.conf" "$config"
REJECT=1
if run_system_setup; then fail "failed preflight must stop setup"; fi
[[ $(cat "$work/calls") == "validate:rc" ]] || fail "failed preflight ran setup"
pass "system setup preserves stable, RC and edge through template restoration and revalidation"
