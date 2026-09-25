#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# An image defers hardware setup to the Mac's first boot, which is often offline,
# and images ship no pacman sync databases. So every package an Apple hardware
# step installs must already be in the Apple default set. The packages come from
# the steps themselves, run on a stubbed Mac where nothing is installed yet.
apple_steps=(
  install/hardware/vulkan.sh
  install/hardware/apple/audio.sh
  install/hardware/apple/video-decode.sh
)
# Reaches a Mac only with the accessory plugged in, and builds DKMS modules for
# the running kernel, so it needs the network anyway. speaker-tuning.sh is not
# listed either: its tunings match on DMI, which a Mac does not have.
accessory_steps=(install/hardware/fix-elgato-camlink-4k.sh)

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$stub_bin/$1"
  chmod +x "$stub_bin/$1"
}
stub omarchy-hw-apple-silicon 'exit 0'
stub omarchy-hw-platform 'echo apple-silicon'
stub lspci 'exit 0'
stub omarchy-pkg-missing 'exit 0'
stub omarchy-pkg-present 'exit 0'
stub omarchy-pkg-add 'printf "%s\n" "$@" >>"$PKG_LOG"'
stub omarchy-setup-mac 'exit 0'

# Every hardware step that installs a package behind the Apple detector is one
# of the steps above.
while IFS= read -r step; do
  grep -q 'omarchy-hw-apple-silicon' "$ROOT/$step" && grep -q 'omarchy-pkg-add' "$ROOT/$step" || continue
  [[ " ${apple_steps[*]} ${accessory_steps[*]} " == *" $step "* ]] ||
    fail "$step installs packages on Apple Silicon: list it here so the Apple default set is checked for them"
done < <(sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(hardware/[^"]*\)"$|install/\1|p' "$ROOT/install/hardware/all.sh")
pass "every Apple hardware step that installs packages is checked"

step_packages=()
for step in "${apple_steps[@]}"; do
  export PKG_LOG="$test_tmp/${step//\//_}.packages"
  : >"$PKG_LOG"
  OMARCHY_PATH="$ROOT" PATH="$stub_bin:/usr/bin:/bin" bash -eE -c 'source "$1"' bash "$ROOT/$step" >/dev/null 2>&1 ||
    fail "$step runs on a stubbed Mac"
  [[ -s $PKG_LOG ]] || fail "$step installs packages on a stubbed Mac; if its gate changed, update this test"
  while IFS= read -r package; do
    step_packages+=("$step:$package")
  done <"$PKG_LOG"
done

# Prints each step package the Apple default set composed from OMARCHY_PATH lacks.
missing_from_defaults() {
  local defaults entry
  defaults=$(OMARCHY_PATH="$1" "$ROOT/bin/omarchy-pkg-defaults" apple-silicon)
  for entry in "${step_packages[@]}"; do
    grep -Fxq "${entry#*:}" <<<"$defaults" || printf '%s\n' "$entry"
  done
}

missing=$(missing_from_defaults "$ROOT")
[[ -z $missing ]] || fail "the Apple default set carries every package an Apple hardware step installs" "$missing"
pass "the Apple default set carries every package an Apple hardware step installs ($(printf '%s\n' "${step_packages[@]#*:}" | sort -u | tr '\n' ' '))"

# Dropping one of them from the Apple list is caught.
mkdir -p "$test_tmp/omarchy/install"
cp "$ROOT"/install/omarchy-{base,aarch64}.packages "$test_tmp/omarchy/install/"
grep -vx vulkan-asahi "$ROOT/install/omarchy-apple.packages" >"$test_tmp/omarchy/install/omarchy-apple.packages"
[[ $(missing_from_defaults "$test_tmp/omarchy") == "install/hardware/vulkan.sh:vulkan-asahi" ]] ||
  fail "a step package dropped from the Apple list is reported" "$(missing_from_defaults "$test_tmp/omarchy")"
pass "a step package dropped from the Apple list is reported"

# The image also carries the tool that picks the startup volume from Linux.
OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-pkg-defaults" apple-silicon | grep -Fxq asahi-bless ||
  fail "the Apple default set carries asahi-bless"
pass "the Apple default set carries asahi-bless"
