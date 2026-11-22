#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"
config="$test_tmp/pacman.conf"
calls="$test_tmp/calls"
cat >"$config" <<'CONF'
[options]
Architecture = aarch64
[custom]
SigLevel = Optional TrustAll
Server = https://custom.example
[omarchy-aarch64]
SigLevel = Optional TrustAll
Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/rc
[later]
SigLevel = Never
Server = file:///later
CONF

cat >"$test_tmp/bin/sudo" <<'SH'
#!/bin/bash
if [[ $1 == pacman-key && $2 == --populate ]]; then echo "populate $3" >>"$TEST_CALLS"; exit 0; fi
if [[ $1 == pacman-key && $2 == --finger ]]; then
  printf 'Key fingerprint = FBD6 874D 423C 418D DB6D  143E ECE1 9CDD E306 DBD2\n'
  exit 0
fi
exec "$@"
SH
chmod +x "$test_tmp/bin/sudo"
export PATH="$test_tmp/bin:$PATH" TEST_CALLS="$calls" OMARCHY_PATH="$ROOT"
omarchy-pkg-missing() { return 1; }

sed "s|/etc/pacman.conf|$config|g" "$ROOT/migrations/1789317000.sh" >"$test_tmp/migration.sh"
(source "$test_tmp/migration.sh" >/dev/null)

source "$ROOT/install/helpers/arm-channel.sh"
omarchy_arm_signature_policy_assert "$config" 'PackageRequired DatabaseRequired TrustedOnly' ||
  fail 'signed RC migration did not establish effective strict policy'
sed -n '/^\[custom\]/,/^\[/p' "$config" | grep -qxF 'SigLevel = Optional TrustAll' ||
  fail 'signed RC migration changed another repository'
sed -n '/^\[later\]/,$p' "$config" | grep -qxF 'SigLevel = Never' ||
  fail 'signed RC migration changed a later repository'
[[ $(cat "$calls") == 'populate omarchy-mac' ]] || fail 'signed RC migration did not populate exact keyring once'

omarchy-pkg-missing() { return 0; }
if (source "$test_tmp/migration.sh" >/dev/null 2>&1); then
  fail 'signed RC migration accepts a client that skipped the trust bootstrap'
fi
pass 'signed RC enforces package/database signatures only after verified bootstrap trust'
