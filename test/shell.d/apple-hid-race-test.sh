#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/fix-asahi-hid-race.sh"
all="$ROOT/install/hardware/all.sh"
migration="$ROOT/migrations/1787433315.sh"
touchpad="$ROOT/bin/omarchy-hw-touchpad"

require_command jq

grep -q 'apple/fix-asahi-hid-race.sh' "$all" ||
  fail "the HID early-load runs during hardware setup"
pass "the HID early-load runs during hardware setup"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
conf="$test_tmp/etc/mkinitcpio.conf.d/apple_hid_modules.conf"
compatible="$test_tmp/device-tree-compatible"
mkdir -p "$stub_bin"

# The leaf reads the architecture and the device tree from absolute paths, so
# every case has to say which machine it runs on rather than inherit the one
# the suite happens to be running on.
cat >"$stub_bin/uname" <<'SH'
#!/bin/bash

if [[ ${1:-} == "-m" ]]; then
  echo "${ARCH:-aarch64}"
else
  exec /usr/bin/uname "$@"
fi
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

printf 'sudo' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
"$@"
SH

cat >"$stub_bin/mkinitcpio" <<'SH'
#!/bin/bash

printf 'mkinitcpio' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
exit "${MKINITCPIO_STATUS:-0}"
SH

# Stubbed rather than run: the real one would write the running user's state.
cat >"$stub_bin/omarchy-state" <<'SH'
#!/bin/bash

printf 'omarchy-state' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
SH

# MODULES_PRESENT names the modules this kernel builds, so a kernel missing one
# can be tested on a machine that has both.
cat >"$stub_bin/modinfo" <<'SH'
#!/bin/bash

module="${!#}"
[[ " ${MODULES_PRESENT-hid_apple hid_magicmouse} " == *" $module "* ]]
SH

chmod +x "$stub_bin"/*

# Redirect the two absolute paths the leaf touches into the sandbox.
sandboxed_leaf="$test_tmp/leaf.sh"
sed -e "s|/etc/mkinitcpio.conf.d|$test_tmp/etc/mkinitcpio.conf.d|g" \
    -e "s|/proc/device-tree/compatible|$compatible|g" \
    "$leaf" >"$sandboxed_leaf"

run_leaf() {
  local arch="${1:-aarch64}" model="${2:-apple,j413}"
  rm -rf "$test_tmp/etc"
  : >"$calls"
  printf '%s' "$model" >"$compatible"

  OMARCHY_UNAME_M="$arch" OMARCHY_APPLE_COMPATIBLE="$compatible" \
    ARCH="$arch" TEST_LOG="$calls" PATH="$stub_bin:$ROOT/bin:$PATH" \
    bash -eE -o pipefail -c 'source "$1"' bash "$sandboxed_leaf" </dev/null
}

run_leaf aarch64 'apple,j413' >/dev/null
[[ -f $conf ]] || fail "an Apple Silicon Mac gets the drop-in" "$(ls -R "$test_tmp/etc" 2>&1)"
pass "an Apple Silicon Mac gets the drop-in"

# The T2 Macs have their own leaf, and it writes hid_apple into an initramfs
# that has no dockchannel-hid to race with.
run_leaf x86_64 'apple,macbookpro' >/dev/null
[[ ! -f $conf ]] || fail "an Intel Mac is left alone" "$(cat "$conf")"
pass "an Intel Mac is left alone"

run_leaf aarch64 'raspberrypi,4-model-b' >/dev/null
[[ ! -f $conf ]] || fail "other aarch64 hardware is left alone" "$(cat "$conf")"
pass "other aarch64 hardware is left alone"

# mkinitcpio sources the drop-in and dies on a MODULES entry it cannot find, so
# what the file does when a driver is missing decides whether every later
# rebuild works -- kernel upgrades included.
source_conf() {
  local present="$1"

  MODULES_PRESENT="$present" PATH="$stub_bin:$PATH" bash -c '
    MODULES=(btrfs)
    source "$1"
    status=$?
    printf "%s\n" "$status" "${MODULES[*]}" "$(declare -p _omarchy_apple_hid_module 2>/dev/null || echo unset)"
  ' bash "$conf"
}

run_leaf >/dev/null
mapfile -t sourced < <(source_conf "hid_apple hid_magicmouse")
[[ ${sourced[0]} == "0" ]] || fail "the drop-in sources cleanly" "status ${sourced[0]}"
[[ ${sourced[1]} == "btrfs hid_apple hid_magicmouse" ]] ||
  fail "both drivers are early-loaded where the kernel builds them" "MODULES=(${sourced[1]})"
[[ ${sourced[2]} == "unset" ]] ||
  fail "the drop-in leaves no variable behind in mkinitcpio's config" "${sourced[2]}"
pass "both drivers are early-loaded where the kernel builds them"

# A kernel with one of them built in, or gone: naming it anyway would fail the
# whole image, and taking both out would drop the driver that is still there.
mapfile -t sourced < <(source_conf "hid_apple")
[[ ${sourced[0]} == "0" ]] || fail "a kernel missing one driver still sources cleanly" "status ${sourced[0]}"
[[ ${sourced[1]} == "btrfs hid_apple" ]] ||
  fail "a driver the kernel does not build is left out" "MODULES=(${sourced[1]})"
pass "a driver the kernel does not build is left out"

mapfile -t sourced < <(source_conf "")
[[ ${sourced[0]} == "0" ]] || fail "a kernel building neither driver still sources cleanly" "status ${sourced[0]}"
[[ ${sourced[1]} == "btrfs" ]] || fail "neither driver is named" "MODULES=(${sourced[1]})"
pass "a kernel building neither driver still sources cleanly"

# Installs that predate the leaf never ran it, so the migration has to reach
# them. omarchy-migrate runs migrations under bash -euo pipefail.
run_migration() {
  local arch="${1:-aarch64}" model="${2:-apple,j413}" mkinitcpio_status="${3:-0}"
  : >"$calls"
  printf '%s' "$model" >"$compatible"

  OMARCHY_UNAME_M="$arch" OMARCHY_APPLE_COMPATIBLE="$compatible" \
    ARCH="$arch" TEST_LOG="$calls" PATH="$stub_bin:$ROOT/bin:$PATH" \
    MKINITCPIO_STATUS="$mkinitcpio_status" \
    OMARCHY_PATH="$test_tmp/omarchy" OMARCHY_APPLE_HID_CONF="$conf" \
    bash -euo pipefail "$migration"
}

# The migration runs the leaf out of OMARCHY_PATH, so the sandbox needs it
# where an install keeps it.
mkdir -p "$test_tmp/omarchy/install/hardware/apple"
cp "$sandboxed_leaf" "$test_tmp/omarchy/install/hardware/apple/fix-asahi-hid-race.sh"

rm -rf "$test_tmp/etc"
run_migration >/dev/null
[[ -f $conf ]] || fail "the migration fixes an install that never ran the leaf" "$(ls -R "$test_tmp/etc" 2>&1)"
grep -Fq $'mkinitcpio\t-P' "$calls" ||
  fail "the migration rebuilds the initramfs that carries MODULES" "$(cat "$calls")"
grep -Fq $'omarchy-state\tset\treboot-required' "$calls" ||
  fail "the migration asks for the reboot that applies it" "$(cat "$calls")"
pass "the migration fixes an install that never ran the leaf"

run_migration >/dev/null
[[ ! -s $calls ]] || fail "a repaired install is left untouched" "$(cat "$calls")"
pass "the migration is idempotent"

# A failed rebuild leaves the running initramfs as it was, so there is nothing
# for a reboot to apply.
rm -rf "$test_tmp/etc"
run_migration aarch64 'apple,j413' 1 >/dev/null 2>&1
grep -Fq $'mkinitcpio\t-P' "$calls" || fail "a failed rebuild is still attempted" "$(cat "$calls")"
! grep -Fq 'omarchy-state' "$calls" ||
  fail "a failed rebuild does not ask for a reboot" "$(cat "$calls")"
pass "a failed rebuild does not ask for a reboot"

rm -rf "$test_tmp/etc"
run_migration x86_64 'apple,macbookpro' >/dev/null
[[ ! -e $conf ]] || fail "the migration skips an Intel Mac" "$(cat "$conf")"
! grep -Fq 'mkinitcpio' "$calls" ||
  fail "the migration rebuilds nothing on an Intel Mac" "$(cat "$calls")"
pass "the migration skips hardware without the race"

# Hyprland names the internal trackpad after its MTP HID interface, so the
# device the menu gates on says neither touchpad nor trackpad.
cat >"$stub_bin/hyprctl" <<'SH'
#!/bin/bash

jq -n --arg name "${MOUSE_NAME:-}" \
  '{mice: (if $name == "" then [] else [{name: $name}] end), keyboards: []}'
SH
chmod +x "$stub_bin/hyprctl"

detected() {
  MOUSE_NAME="$1" PATH="$stub_bin:$PATH" bash "$touchpad"
}

[[ $(detected "apple-mtp-multi-touch") == "apple-mtp-multi-touch" ]] ||
  fail "the Apple Silicon trackpad is detected" "$(detected "apple-mtp-multi-touch")"
pass "the Apple Silicon trackpad is detected"

# omarchy-toggle-input-device passes the name straight to hl.device, so a name
# that does not match leaves the menu entry hidden and the toggle dead.
for name in "elan-touchpad" "apple-magic-trackpad-2"; do
  [[ $(detected "$name") == "$name" ]] || fail "the touchpads that already worked still do" "$name"
done
pass "the touchpads that already worked still do"

[[ -z $(detected "logitech-mx-master-3") ]] ||
  fail "an ordinary mouse is not mistaken for a touchpad" "$(detected "logitech-mx-master-3")"
pass "an ordinary mouse is not mistaken for a touchpad"
