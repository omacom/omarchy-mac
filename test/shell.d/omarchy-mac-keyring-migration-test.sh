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
SigLevel = Required DatabaseOptional
[custom]
SigLevel = Optional TrustAll
Server = https://custom.example
  [omarchy-aarch64]
  SigLevel   = Optional TrustAll
Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/rc
[later]
SigLevel = Never
Server = file:///later
CONF

cat >"$test_tmp/bin/sudo" <<'SH'
#!/bin/bash
if [[ $1 == pacman-key && $2 == --populate ]]; then
  echo "populate $3" >>"$TEST_CALLS"
  exit 0
fi
if [[ $1 == pacman-key && $2 == --finger ]]; then
  printf 'Key fingerprint = F3C5 AE3F CFFC 738C 301E  30A8 F0C5 48C0 D272 79F7\n'
  exit 0
fi
exec "$@"
SH
chmod +x "$test_tmp/bin/sudo"

omarchy-pkg-missing() { return 1; }
omarchy-pkg-add() { echo "add $*" >>"$calls"; }
export TEST_CALLS="$calls"
export PATH="$test_tmp/bin:$PATH"
export OMARCHY_PATH="$ROOT"

# Redirect only the fixture's machine config reference.
sed "s|/etc/pacman.conf|$config|g" "$ROOT/migrations/1789316115.sh" >"$test_tmp/migration.sh"
(source "$test_tmp/migration.sh" >/dev/null)
(source "$test_tmp/migration.sh" >/dev/null)

[[ $(grep -c '^populate omarchy-mac$' "$calls") == 2 ]] || fail 'migration repopulates trust idempotently'
grep -qxF '  SigLevel   = Optional TrustAll' "$config" ||
  fail 'bootstrap migration changed policy before the signed repository exists'
sed -n '/^\[custom\]/,/^\[/p' "$config" | grep -qxF 'SigLevel = Optional TrustAll' ||
  fail 'migration changed another repository policy'
sed -n '/^\[later\]/,$p' "$config" | grep -qxF 'SigLevel = Never' ||
  fail 'migration changed a later repository policy'
pass 'existing installs populate fork trust while retaining the one-time bootstrap policy'

source "$ROOT/install/helpers/arm-channel.sh"
missing="$test_tmp/missing-policy.conf"
sed '/SigLevel   = Optional TrustAll/d' "$config" >"$missing"
omarchy_arm_signature_policy_render "$missing" 'PackageRequired DatabaseOptional TrustedOnly' "$test_tmp/rendered"
omarchy_arm_signature_policy_assert "$test_tmp/rendered" 'PackageRequired DatabaseOptional TrustedOnly' ||
  fail 'renderer does not establish effective policy when the stanza inherited one'

ln -s "$config" "$test_tmp/pacman-link.conf"
if omarchy_arm_signature_policy_apply "$test_tmp/pacman-link.conf" 'PackageRequired DatabaseOptional TrustedOnly' >/dev/null 2>&1; then
  fail 'policy application follows a pacman.conf symlink'
fi
pass 'policy rendering handles formatting and missing overrides while application rejects symlinks'
