#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# Exercise main's real ordering with a base that has yay but no validator
# tools. The mocked pacman transaction makes those tools available; a preflight
# attempt before it must fail, just as python3 would on a fresh ALARM image.
eval "$(sed -n '/^ensure_channel_tools() {/,/^}/p' "$ROOT/install.sh")"
eval "$(sed -n '/^main() {/,/^}/p' "$ROOT/install.sh")"
tools_ready=0
validated=0
sudo() {
  [[ $* == 'pacman -S --needed --noconfirm python curl libarchive' ]] || fail 'bootstrap installs the validator tools from existing repositories'
  tools_ready=1
}
check_preconditions() { :; }
ensure_utf8_locale() { :; }
ensure_arm_package_repo() {
  (( tools_ready )) || fail 'fresh-install repository validation ran without Python'
  validated=$((validated + 1))
}
ensure_gum() { :; }
ensure_aur_helper() { :; } # yay already installed; this path installs nothing.
ensure_package_sources() { :; }
build_omarchy_packages() { :; }
install_omarchy_packages() { :; }
install_default_package_set() { :; }
seed_user_defaults() { :; }
run_system_setup() { ensure_arm_package_repo; }
snapshot_factory_baseline() { :; }
log() { :; }
main
(( validated == 2 )) || fail 'initial and post-system-setup validation must both run with tools available'
pass 'fresh installation bootstraps Python before repository validation even with yay already present'

# Missing Python in standalone recovery must fail before helper downloads or
# any privileged work. Only uname is needed before this dependency check.
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"
printf '[options]\nArchitecture = aarch64\n' > "$test_tmp/pacman.conf"
printf '#!/bin/bash\nprintf "aarch64\\n"\n' > "$test_tmp/bin/uname"
printf '#!/bin/bash\necho called >> "%s"\nexit 99\n' "$test_tmp/mutations" > "$test_tmp/bin/sudo"
chmod +x "$test_tmp/bin/uname" "$test_tmp/bin/sudo"
if PATH="$test_tmp/bin" OMARCHY_ARM_PACMAN_CONF="$test_tmp/pacman.conf" \
  /bin/bash "$ROOT/fix-arm-packages.sh" --no-snapshot > "$test_tmp/out" 2>&1; then
  fail 'standalone recovery must reject missing Python'
fi
grep -q 'Recovery requires python3' "$test_tmp/out" || fail 'recovery explains the missing interpreter' "$(cat "$test_tmp/out")"
[[ ! -e $test_tmp/mutations ]] || fail 'missing interpreter must fail before privilege escalation'
pass 'standalone recovery reports missing Python before changing the system'
