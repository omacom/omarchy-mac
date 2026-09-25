#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/install/helpers/arm-channel.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin" "$test_tmp/home"
config="$test_tmp/pacman.conf"
cat >"$config" <<'CONF'
[options]
Architecture = aarch64
IgnorePkg = locally-pinned
[private-first]
Server = https://private.example/$arch
[omarchy-aarch64]
SigLevel = Optional TrustAll
Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge
[core]
Include = /etc/pacman.d/my-custom-mirrorlist
[private-last]
Server = https://last.example/$arch
CONF
cp "$config" "$test_tmp/original"
for lane in stable rc edge; do
  omarchy_arm_channel_render "$config" "$lane" "$test_tmp/staged"
  [[ $(omarchy_arm_channel_current "$test_tmp/staged") == "$lane" ]] || fail "detect rendered $lane"
  sed "s|/download/edge|/download/$lane|" "$test_tmp/original" >"$test_tmp/expected"
  cmp "$test_tmp/staged" "$test_tmp/expected" || fail "$lane preserves all custom sections, options and mirror Includes in place"
  [[ $(omarchy_arm_channel_current "$ROOT/default/pacman/pacman-$lane.conf") == "$lane" ]] || fail "$lane template selects its own ARM feed"
done
cmp "$config" "$test_tmp/original" || fail 'staging never modifies the active config'
pass 'ARM lanes are distinct and staging preserves custom repository order and mirrors'

for layout in custom-server include duplicate missing; do
  cp "$test_tmp/original" "$test_tmp/custom"
  case "$layout" in
    custom-server) sed -i 's|https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge|https://custom.example/edge|' "$test_tmp/custom" ;;
    include) sed -i '/^\[omarchy-aarch64\]/a Include = /etc/pacman.d/custom-lane' "$test_tmp/custom" ;;
    duplicate) printf '\n[omarchy-aarch64]\nServer = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/rc\n' >>"$test_tmp/custom" ;;
    missing) sed -i 's/\[omarchy-aarch64\]/[user-repository]/' "$test_tmp/custom" ;;
  esac
  cp "$test_tmp/custom" "$test_tmp/custom-before"
  if omarchy_arm_channel_render "$test_tmp/custom" rc "$test_tmp/rejected" >/dev/null 2>&1; then
    fail "$layout must not be guessed or overwritten"
  fi
  cmp "$test_tmp/custom" "$test_tmp/custom-before" || fail "$layout config is preserved"
done
pass 'custom and ambiguous ARM repository layouts fail without modification'

printf '%s\n' '[options]' 'Architecture = aarch64' '[extra]' 'Server = https://regular.example/$arch' >"$test_tmp/fresh"
cp "$test_tmp/fresh" "$test_tmp/fresh-before"
omarchy_arm_channel_render "$test_tmp/fresh" rc "$test_tmp/fresh-rendered" fresh
[[ $(omarchy_arm_channel_current "$test_tmp/fresh-rendered") == rc ]] || fail 'fresh candidate adds explicit RC lane'
grep -qxF 'SigLevel = PackageRequired DatabaseRequired TrustedOnly' "$test_tmp/fresh-rendered" ||
  fail 'fresh signed RC requires trusted package and database signatures'
cmp "$test_tmp/fresh" "$test_tmp/fresh-before" || fail 'fresh render preserves active configuration'
printf '%s\n' '[omarchy-aarch64]' 'Server = https://custom.example/repo' >"$test_tmp/hidden"
printf 'Include = %s\n' "$test_tmp/hidden" >>"$test_tmp/fresh"
if omarchy_arm_channel_render "$test_tmp/fresh" rc "$test_tmp/rejected" fresh >/dev/null 2>&1; then
  fail 'fresh installer must not shadow a hidden custom ARM repository'
fi
pass 'fresh candidates add a missing lane but reject hidden custom repositories'

omarchy_arm_channel_render "$config" rc "$test_tmp/existing-fresh-rendered" fresh
grep -qxF 'SigLevel = PackageRequired DatabaseRequired TrustedOnly' "$test_tmp/existing-fresh-rendered" ||
  fail 'fresh signed RC leaves an existing managed stanza permissive'
sed -n '/^\[private-first\]/,/^\[/p' "$test_tmp/existing-fresh-rendered" |
  grep -qxF 'Server = https://private.example/$arch' || fail 'fresh strict render changed another repository'
cmp "$config" "$test_tmp/original" || fail 'fresh strict render modified the active configuration'
pass 'fresh signed RC hardens an existing managed lane before preflight'

for template in "$ROOT/default/pacman/pacman.conf" "$ROOT/default/pacman/pacman-stable.conf" \
  "$ROOT/default/pacman/pacman-rc.conf" "$ROOT/default/pacman/pacman-edge.conf"; do
  sed -n '/^\[omarchy-aarch64\]/,/^\[/p' "$template" |
    grep -qxF 'SigLevel = PackageRequired DatabaseRequired TrustedOnly' ||
    fail "strict signed-RC policy missing from $template"
done
pass 'all shipped ARM repository templates require the trusted fork signer'

printf '#!/bin/bash\necho aarch64\n' >"$test_tmp/bin/uname"
cat >"$test_tmp/bin/omarchy-update" <<'SH'
#!/bin/bash
echo "update $* lane=${OMARCHY_UPDATE_CHANNEL:-}" >>"$TEST_CHANNEL_CALLS"
exit "${TEST_CHANNEL_FAILURE:-0}"
SH
cat >"$test_tmp/bin/pacman" <<'SH'
#!/bin/bash
[[ $* == '-Q omarchy omarchy-settings' ]]
SH
for command in omarchy-refresh-pacman sudo omarchy-dev-unlink omarchy-state omarchy-dev-link; do
  printf '#!/bin/bash\necho "%s $*" >>"$TEST_CHANNEL_CALLS"\n' "$command" >"$test_tmp/bin/$command"
done
printf '#!/bin/bash\nexit 0\n' >"$test_tmp/bin/gum"
cat >"$test_tmp/bin/git" <<'SH'
#!/bin/bash
echo "git $*" >>"$TEST_CHANNEL_CALLS"
mkdir -p "${@: -1}/.git" "${@: -1}/bin" "${@: -1}/default" "${@: -1}/shell"
SH
chmod +x "$test_tmp/bin/"*
export TEST_CHANNEL_CALLS="$test_tmp/calls"
for lane in stable rc edge; do
  : >"$TEST_CHANNEL_CALLS"
  HOME="$test_tmp/home" OMARCHY_PATH=/usr/share/omarchy PATH="$test_tmp/bin:$ROOT/bin:$PATH" \
    bash "$ROOT/bin/omarchy-channel-set" "$lane"
  [[ $(cat "$TEST_CHANNEL_CALLS") == "update -y lane=$lane" ]] || fail "$lane must invoke one update pipeline without separate package or refresh transactions"
done
pass 'ARM channel selection delegates exactly once to the normal update pipeline'

HOME="$test_tmp/home" OMARCHY_PATH="$ROOT" OMARCHY_PACMAN_CONFIG="$config" PATH="$test_tmp/bin:$PATH" \
  bash "$ROOT/bin/omarchy-version-channel" >"$test_tmp/version"
[[ $(cat "$test_tmp/version") == edge ]] || fail 'legacy edge feed reports edge despite stable-named packages'
printf '#!/bin/bash\necho edge\n' >"$test_tmp/bin/omarchy-version-channel"
chmod +x "$test_tmp/bin/omarchy-version-channel"
[[ $(OMARCHY_PATH=/usr/share/omarchy PATH="$test_tmp/bin:$PATH" bash "$ROOT/bin/omarchy-channel-current") == edge ]] || fail 'stable-named ARM pair can report the actual edge lane'
pass 'ARM channel reporting follows the configured feed rather than x86 package names'

: >"$TEST_CHANNEL_CALLS"
if HOME="$test_tmp/home" TEST_CHANNEL_FAILURE=1 OMARCHY_PATH=/usr/share/omarchy PATH="$test_tmp/bin:$ROOT/bin:$PATH" \
  bash "$ROOT/bin/omarchy-channel-set" dev >/dev/null 2>&1; then
  fail 'failed ARM channel update cannot report successful dev selection'
fi
[[ $(cat "$TEST_CHANNEL_CALLS") == 'update -y lane=edge' ]] || fail 'failed lane cannot clone or link a dev checkout'
: >"$TEST_CHANNEL_CALLS"
HOME="$test_tmp/home" OMARCHY_PATH=/usr/share/omarchy PATH="$test_tmp/bin:$ROOT/bin:$PATH" \
  bash "$ROOT/bin/omarchy-channel-set" dev >/dev/null
[[ $(head -1 "$TEST_CHANNEL_CALLS") == 'update -y lane=edge' ]] || fail 'successful package transaction precedes dev linkage'
grep -q '^git clone https://github.com/omacom/omarchy-mac.git ' "$TEST_CHANNEL_CALLS" || fail 'ARM dev uses the Mac source repository'
pass 'ARM dev linkage occurs only after successful package update'
