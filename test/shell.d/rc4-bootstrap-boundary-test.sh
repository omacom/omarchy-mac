#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/install/helpers/arm-channel.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

[[ $(cat "$ROOT/version") == 4.0.3rc4 ]] || fail 'bootstrap source version is not RC4'
[[ ! -e $ROOT/migrations/1789317000.sh ]] || fail 'RC5 strict migration leaked into RC4'
[[ ! -e $ROOT/migrations/1789390468.sh ]] || fail 'redundant transition migration remains in RC4'
for policy in 'Optional TrustAll' 'PackageRequired DatabaseRequired TrustedOnly'; do
  cat >"$test_tmp/config" <<CONF
[options]
Architecture = aarch64
[omarchy-aarch64]
SigLevel = $policy
Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge
CONF
  cp "$test_tmp/config" "$test_tmp/original"
  for mode in fresh existing; do
    omarchy_arm_channel_render "$test_tmp/config" rc "$test_tmp/rendered" "$mode"
    before=$(pacman-conf --config "$test_tmp/config" --repo omarchy-aarch64 SigLevel | sort)
    after=$(pacman-conf --config "$test_tmp/rendered" --repo omarchy-aarch64 SigLevel | sort)
    [[ $before == "$after" ]] || fail "$mode changed $policy"
    cmp "$test_tmp/config" "$test_tmp/original" || fail 'preflight changed input config'
  done
done
pass 'RC4 lane rendering neither activates strict signing nor downgrades stricter clients'

# Run all bootstrap trust migrations through the real marker-based runner.
# Privileged operations are restricted to a public-key populate and fingerprint.
export TEST_CALLS="$test_tmp/calls"
sudo() {
  printf '%s\n' "$*" >>"$TEST_CALLS"
  case "$*" in
    'pacman-key --populate omarchy-mac') return 0 ;;
    'pacman-key --finger FBD6874D423C418DDB6D143EECE19CDDE306DBD2')
      printf '%s\n' FBD6874D423C418DDB6D143EECE19CDDE306DBD2 ;;
    *) return 99 ;;
  esac
}
pacman() {
  [[ $* == '-Q omarchy-mac-keyring' ]] || return 99
  printf '%s\n' 'omarchy-mac-keyring 20260914-2'
}
omarchy-pkg-missing() { return 1; }
omarchy-notification-dismiss() { :; }
export -f sudo pacman omarchy-pkg-missing omarchy-notification-dismiss
mkdir -p "$test_tmp/source/migrations" "$test_tmp/markers"
for name in 1789316115 1789407944; do
  cp "$ROOT/migrations/$name.sh" "$test_tmp/source/migrations/"
done
OMARCHY_PATH="$test_tmp/source" OMARCHY_MIGRATION_STATE="$test_tmp/markers" bash "$ROOT/bin/omarchy-migrate" >/dev/null
for name in 1789316115 1789407944; do
  [[ -f $test_tmp/markers/$name.sh ]] || fail "$name did not complete"
done
[[ $(grep -c '^pacman-key --populate omarchy-mac$' "$TEST_CALLS") == 2 ]] || fail 'not all trust stages populated'
[[ $(wc -l <"$TEST_CALLS") == 4 ]] || fail 'unexpected privileged operation'
: >"$TEST_CALLS"
OMARCHY_PATH="$test_tmp/source" OMARCHY_MIGRATION_STATE="$test_tmp/markers" bash "$ROOT/bin/omarchy-migrate" >/dev/null
[[ ! -s $TEST_CALLS ]] || fail 'completed bootstrap reran'
pass 'all pending RC4 trust migrations complete without old-key or policy operations'
