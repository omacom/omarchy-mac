#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home"

# Every possible effect in these early guards fails the test instead of running.
cat >"$work/bin/blocked" <<'SH'
#!/bin/bash
printf '%s\n' "$0 $*" >>"$EFFECT_LOG"
exit 99
SH
chmod +x "$work/bin/blocked"
for command in sudo pacman yay gum curl systemctl hyprctl mkdir cp mv rm mise omarchy-pkg-add omarchy-refresh-applications; do
  ln -s blocked "$work/bin/$command"
done
cat >"$work/bin/uname" <<'SH'
#!/bin/bash
printf '%s\n' "${TEST_UNAME_OUTPUT:-aarch64}"
exit "${TEST_UNAME_STATUS:-0}"
SH
chmod +x "$work/bin/uname"
export EFFECT_LOG="$work/effects" HOME="$work/home" OMARCHY_PATH="$ROOT" OMARCHY_INSTALL="$ROOT/install"
test_path="$work/bin:$ROOT/bin:/usr/bin:/bin"
commands=(
  bin/omarchy-refresh-pacman bin/omarchy-refresh-pacman-mirrorlist
  bin/omarchy-update-keyring bin/omarchy-update-system-pkgs
  bin/omarchy-hibernation-setup bin/omarchy-windows-vm
  bin/omarchy-install-service-1password bin/omarchy-voxtype-install
  bin/omarchy-install-preinstalls bin/omarchy-remove-preinstalls
  bin/omarchy-install-docker-dbs bin/omarchy-install-gaming-steam
  bin/omarchy-install-gaming-gpu-lib32 install.sh build-packages.sh
)
for scenario in unknown failed; do
  export OMARCHY_UNAME_M=riscv64 TEST_UNAME_STATUS=0
  if [[ $scenario == failed ]]; then
    export OMARCHY_UNAME_M= TEST_UNAME_STATUS=1
  fi
  for script in "${commands[@]}"; do
    if PATH="$test_path" /bin/bash "$ROOT/$script" >"$work/output" 2>&1; then
      fail "$script rejects $scenario architecture before any effect"
    fi
    [[ ! -e $EFFECT_LOG ]] || fail "$script reached a mutator after $scenario detection" "$(cat "$EFFECT_LOG")"
  done
  for leaf in install/post-install/pacman.sh install/post-install/optional-apps.sh install/user/mise-work.sh; do
    if PATH="$test_path" /bin/bash -c 'source "$1"' _ "$ROOT/$leaf" >"$work/output" 2>&1; then
      fail "$leaf rejects $scenario architecture before setup"
    fi
    [[ ! -e $EFFECT_LOG ]] || fail "$leaf reached a mutator after $scenario detection"
  done
done
pass "unsupported and failed architecture detection stop package/configuration mutations"

# Source the moved installer itself, retaining its real checkout resolution and
# preconditions. A stale installed helper must not override the checkout helper.
cat >"$work/bin/omarchy-hw-aarch64" <<'SH'
#!/bin/bash
exit 99
SH
chmod +x "$work/bin/omarchy-hw-aarch64"
printf 'apple,arm-platform\0' >"$work/compatible"
OMARCHY_UNAME_M=arm64 OMARCHY_APPLE_COMPATIBLE="$work/compatible" TEST_UNAME_STATUS=0 PATH="$test_path" /bin/bash -euo pipefail -c '
  source "$1/install/aarch64/install.sh"
  [[ $checkout == "$1" && $package_output == "$1/build-output" ]]
  [[ $(command -v omarchy-hw-aarch64) == "$1/bin/omarchy-hw-aarch64" ]]
  check_preconditions
' _ "$ROOT" >"$work/output" 2>&1 || fail "the moved installer uses its checkout with an older installed PATH" "$(cat "$work/output")"
[[ ! -e $EFFECT_LOG ]] || fail "installer precondition checks performed a mutation"
pass "the moved ARM installer resolves repository paths and bootstraps fresh helpers"

# The real dispatcher in a fixture checkout forwards aliases and arguments to
# the ARM child. This child only records dispatch; it cannot install anything.
mkdir -p "$work/checkout/bin" "$work/checkout/install/aarch64"
cp "$ROOT/install.sh" "$work/checkout/"
cp "$ROOT/bin/omarchy-hw-arch" "$work/checkout/bin/"
cat >"$work/checkout/install/aarch64/install.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$DISPATCH_LOG"
SH
export DISPATCH_LOG="$work/dispatched"
OMARCHY_UNAME_M=arm64 PATH="$test_path" /bin/bash "$work/checkout/install.sh" --example 'two words'
[[ $(cat "$DISPATCH_LOG") == $'--example\ntwo words' ]] || fail "the dispatcher preserves arguments on the ARM alias"
rm "$DISPATCH_LOG"
if OMARCHY_UNAME_M=x86_64 PATH="$test_path" /bin/bash "$work/checkout/install.sh" >"$work/output" 2>&1; then
  fail "x86 does not enter the ARM installer"
fi
[[ ! -e $DISPATCH_LOG ]] && grep -q omarchy.org "$work/output" || fail "x86 keeps the ISO installation route"
pass "root installation dispatches the ARM alias and preserves the x86 ISO route"

# Direct builder use must also reach its own detector when no new Omarchy
# commands have been installed. Stop safely at the intentionally absent makepkg.
mkdir "$work/bootstrap-bin"
ln -s /usr/bin/dirname "$work/bootstrap-bin/dirname"
cp "$work/bin/omarchy-hw-aarch64" "$work/bootstrap-bin/"
if OMARCHY_UNAME_M=arm64 PATH="$work/bootstrap-bin" /bin/bash "$ROOT/build-packages.sh" >"$work/output" 2>&1; then
  fail "the fixture builder stops before any package operation"
fi
grep -q 'makepkg is required' "$work/output" || fail "direct builder resolves its own detector with a clean or stale PATH" "$(cat "$work/output")"
pass "direct package builds find checkout detectors before any installed Omarchy exists"

# Downloaded entrypoints promise to work without any installed Omarchy helper.
# Run their actual guard functions in a shell whose PATH contains only uname.
mkdir "$work/standalone-bin"
cp "$work/bin/uname" "$work/standalone-bin/"
for script in omarchy-upgrade-to-quattro omarchy-upgrade-to-quattro-mac omarchy-system-boot-to-esp omarchy-system-btrfs-migrate omarchy-pkg-publish-aarch64; do
  guard=$(sed -n '/^check_architecture() {/,/^}/p' "$ROOT/bin/$script")
  [[ -n $guard ]] || fail "$script carries its standalone architecture guard"
  for arch in x86_64 aarch64 arm64 unknown; do
    expected=1
    if [[ $script == omarchy-upgrade-to-quattro ]]; then
      [[ $arch != x86_64 ]] || expected=0
    else
      [[ $arch != aarch64 && $arch != arm64 ]] || expected=0
    fi
    status=0
    GUARD_BODY="$guard" TEST_UNAME_OUTPUT="$arch" TEST_UNAME_STATUS=0 PATH="$work/standalone-bin" /bin/bash -c '
      fail() { exit 1; }
      eval "$GUARD_BODY"
      check_architecture
    ' || status=$?
    (( status == expected )) || fail "$script handles $arch without installed helpers"
  done
  if GUARD_BODY="$guard" TEST_UNAME_OUTPUT=aarch64 TEST_UNAME_STATUS=1 PATH="$work/standalone-bin" /bin/bash -c '
    fail() { exit 1; }
    eval "$GUARD_BODY"
    check_architecture
  '; then
    fail "$script rejects failed uname even if it prints a recognized architecture"
  fi
done
pass "downloaded upgrade and boot entrypoints retain status-checked standalone guards"
