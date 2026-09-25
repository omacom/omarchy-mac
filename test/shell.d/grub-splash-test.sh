#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls"
mkdir -p "$stub_bin"

# limine presence is the gate; mkinitcpio and grub-mkconfig record their calls.
cat >"$stub_bin/omarchy-cmd-missing" <<'STUB'
#!/bin/bash
[[ $1 == limine ]] && (( ${STUB_LIMINE:-0} == 0 ))
STUB
cat >"$stub_bin/omarchy-cmd-present" <<'STUB'
#!/bin/bash
[[ $1 == grub-mkconfig ]]
STUB
for tool in mkinitcpio grub-mkconfig; do
  cat >"$stub_bin/$tool" <<STUB
#!/bin/bash
echo "$tool \$*" >>"\$OMARCHY_TEST_CALLS"
STUB
done
cat >"$stub_bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
(( ${STUB_APPLE:-1} == 1 ))
STUB
cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
[[ $1 == env ]] && shift
while [[ $1 == *=* ]]; do export "$1"; shift; done
exec "$@"
STUB
chmod +x "$stub_bin"/*

fixture=""
new_fixture() {
  fixture="$test_tmp/$1"
  mkdir -p "$fixture/etc/default" "$fixture/etc/mkinitcpio.conf.d" "$fixture/boot/grub"
  : >"$calls"
}

run_leaf() {
  PATH="$stub_bin:$PATH" OMARCHY_TEST_CALLS="$calls" STUB_LIMINE="${STUB_LIMINE:-0}" \
    OMARCHY_GRUB_DEFAULT="$fixture/etc/default/grub" \
    OMARCHY_GRUB_CFG="$fixture/boot/grub/grub.cfg" \
    OMARCHY_MKINITCPIO_CONF="$fixture/etc/mkinitcpio.conf" \
    OMARCHY_MKINITCPIO_CONF_DIR="$fixture/etc/mkinitcpio.conf.d" \
    OMARCHY_GRUB_SPLASH_PENDING="$fixture/pending" \
    bash -eE -c 'source "$1"' bash "$ROOT/install/login/grub-splash.sh"
}

stock_asahi() {
  printf 'HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)\n' >"$fixture/etc/mkinitcpio.conf"
  printf 'GRUB_DISTRIBUTOR="Arch"\nGRUB_CMDLINE_LINUX_DEFAULT="loglevel=3"\nGRUB_TIMEOUT=5\n' >"$fixture/etc/default/grub"
}

# x86: Limine is installed, so nothing is touched even with a GRUB file around.
new_fixture limine
stock_asahi
STUB_LIMINE=1 run_leaf
[[ ! -s $calls ]] || fail "Limine machines do not rebuild anything" "$(cat "$calls")"
grep -qx 'GRUB_DISTRIBUTOR="Arch"' "$fixture/etc/default/grub" || fail "Limine machines keep their GRUB defaults"
pass "a Limine machine is left alone"

# No GRUB at all: nothing to configure.
new_fixture no-grub
printf 'HOOKS=(base udev block filesystems)\n' >"$fixture/etc/mkinitcpio.conf"
run_leaf
[[ ! -s $calls ]] || fail "a machine without GRUB does not rebuild anything" "$(cat "$calls")"
pass "a machine without /etc/default/grub is left alone"

# Fresh Asahi Alarm: plymouth goes in after base udev, splash and quiet are
# appended, the menu is named Omarchy, and each tool runs once.
new_fixture asahi
stock_asahi
run_leaf
grep -qx 'HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block filesystems fsck)' "$fixture/etc/mkinitcpio.conf" ||
  fail "plymouth is inserted after base udev" "$(cat "$fixture/etc/mkinitcpio.conf")"
grep -qx 'GRUB_DISTRIBUTOR="Omarchy"' "$fixture/etc/default/grub" || fail "GRUB menu entries are named Omarchy"
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash"' "$fixture/etc/default/grub" ||
  fail "quiet and splash are appended to the kernel command line" "$(cat "$fixture/etc/default/grub")"
grep -qx 'GRUB_TIMEOUT=5' "$fixture/etc/default/grub" || fail "unrelated GRUB settings survive"
[[ $(grep -c '^mkinitcpio -P$' "$calls") == 1 ]] || fail "the initramfs is rebuilt once" "$(cat "$calls")"
[[ $(grep -c "^grub-mkconfig -o $fixture/boot/grub/grub.cfg$" "$calls") == 1 ]] || fail "grub.cfg is regenerated once" "$(cat "$calls")"
pass "a fresh Asahi GRUB install gets the plymouth hook, splash, and the Omarchy menu title"

# Second run over the result: nothing changes and nothing is rebuilt.
: >"$calls"
run_leaf
[[ ! -s $calls ]] || fail "a configured machine is not rebuilt again" "$(cat "$calls")"
pass "the leaf is idempotent"

# A drop-in already naming plymouth (the shape of Omarchy's HOOKS baseline) means
# the main file is not edited, but GRUB still gets its options.
new_fixture drop-in
stock_asahi
printf 'HOOKS=(base udev plymouth block filesystems)\n' >"$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
run_leaf
grep -qx 'HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)' "$fixture/etc/mkinitcpio.conf" ||
  fail "mkinitcpio.conf is left alone when a drop-in already has plymouth"
! grep -q '^mkinitcpio' "$calls" || fail "no initramfs rebuild when the hook is already effective"
grep -q '^grub-mkconfig' "$calls" || fail "GRUB is still configured when only the hook was already present"
pass "an existing plymouth drop-in leaves mkinitcpio.conf alone"

# vconsole.conf often has no XKBLAYOUT. A drop-in that expands it must not
# abort the leaf under nounset (how omarchy-migrate sources it).
new_fixture xkb-unset
stock_asahi
cat >"$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf" <<'CONF'
HOOKS=(base udev plymouth block filesystems)
case $(echo "${XKBLAYOUT%%,*}") in
  *) : ;;
esac
CONF
PATH="$stub_bin:$PATH" OMARCHY_TEST_CALLS="$calls" STUB_LIMINE=0 \
  OMARCHY_GRUB_DEFAULT="$fixture/etc/default/grub" \
  OMARCHY_GRUB_CFG="$fixture/boot/grub/grub.cfg" \
  OMARCHY_MKINITCPIO_CONF="$fixture/etc/mkinitcpio.conf" \
  OMARCHY_MKINITCPIO_CONF_DIR="$fixture/etc/mkinitcpio.conf.d" \
  OMARCHY_GRUB_SPLASH_PENDING="$fixture/pending" \
  bash -euo pipefail -c 'source "$1"' bash "$ROOT/install/login/grub-splash.sh"
grep -qx 'GRUB_DISTRIBUTOR="Omarchy"' "$fixture/etc/default/grub" ||
  fail "nounset XKBLAYOUT in a drop-in does not abort GRUB branding"
pass "sourcing drop-ins survives an unset XKBLAYOUT"

# Single-quoted and unquoted command lines keep their quote style when possible.
new_fixture quoted
printf 'HOOKS=(base udev plymouth block filesystems)\n' >"$fixture/etc/mkinitcpio.conf"
printf "GRUB_CMDLINE_LINUX_DEFAULT='loglevel=3'\n" >"$fixture/etc/default/grub"
run_leaf
grep -qx "GRUB_CMDLINE_LINUX_DEFAULT='loglevel=3 quiet splash'" "$fixture/etc/default/grub" ||
  fail "a single-quoted command line keeps single quotes" "$(cat "$fixture/etc/default/grub")"
pass "single-quoted GRUB_CMDLINE_LINUX_DEFAULT is preserved"

new_fixture unquoted
printf 'HOOKS=(base udev plymouth block filesystems)\n' >"$fixture/etc/mkinitcpio.conf"
printf 'GRUB_CMDLINE_LINUX_DEFAULT=quiet\n' >"$fixture/etc/default/grub"
run_leaf
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' "$fixture/etc/default/grub" ||
  fail "an unquoted command line is quoted once it gains spaces" "$(cat "$fixture/etc/default/grub")"
pass "unquoted GRUB_CMDLINE_LINUX_DEFAULT gains quotes when needed"

# A failed initramfs rebuild stays pending so the next run retries even though
# plymouth is already in HOOKS.
new_fixture rebuild-fail
stock_asahi
cat >"$stub_bin/mkinitcpio" <<STUB
#!/bin/bash
echo "mkinitcpio \$*" >>"\$OMARCHY_TEST_CALLS"
exit 1
STUB
chmod +x "$stub_bin/mkinitcpio"
status=0
run_leaf || status=$?
(( status != 0 )) || fail "a failed mkinitcpio fails the leaf"
[[ -f $fixture/pending ]] || fail "a failed rebuild leaves a pending marker"
grep -qx 'HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block filesystems fsck)' "$fixture/etc/mkinitcpio.conf" ||
  fail "plymouth stays in HOOKS after a failed rebuild"
cat >"$stub_bin/mkinitcpio" <<STUB
#!/bin/bash
echo "mkinitcpio \$*" >>"\$OMARCHY_TEST_CALLS"
STUB
chmod +x "$stub_bin/mkinitcpio"
: >"$calls"
run_leaf
grep -q '^mkinitcpio -P$' "$calls" || fail "the next run retries mkinitcpio" "$(cat "$calls")"
[[ ! -e $fixture/pending ]] || fail "a successful rebuild clears the pending marker"
pass "a failed initramfs rebuild is retried"

# GRUB file without a default command line: the line is added, not lost.
new_fixture no-cmdline
printf 'HOOKS=(base udev plymouth block filesystems)\n' >"$fixture/etc/mkinitcpio.conf"
printf 'GRUB_TIMEOUT=5\n' >"$fixture/etc/default/grub"
run_leaf
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' "$fixture/etc/default/grub" || fail "a missing command line is created"
grep -qx 'GRUB_DISTRIBUTOR="Omarchy"' "$fixture/etc/default/grub" || fail "a missing distributor is created"
pass "GRUB defaults without the expected lines gain them"

# The migration reaches the leaf on Apple Silicon and is a no-op elsewhere.
migration="$ROOT/migrations/1789158178.sh"
[[ -f $migration ]] || fail "GRUB splash migration exists"
new_fixture migration-x86
stock_asahi
STUB_APPLE=0 PATH="$stub_bin:$PATH" OMARCHY_PATH="$ROOT" OMARCHY_TEST_CALLS="$calls" \
  OMARCHY_GRUB_DEFAULT="$fixture/etc/default/grub" OMARCHY_GRUB_CFG="$fixture/boot/grub/grub.cfg" \
  OMARCHY_MKINITCPIO_CONF="$fixture/etc/mkinitcpio.conf" OMARCHY_MKINITCPIO_CONF_DIR="$fixture/etc/mkinitcpio.conf.d" \
  OMARCHY_GRUB_SPLASH_PENDING="$fixture/pending" \
  bash -euo pipefail "$migration" >/dev/null
[[ ! -s $calls ]] || fail "the migration does nothing off Apple Silicon" "$(cat "$calls")"
grep -qx 'GRUB_DISTRIBUTOR="Arch"' "$fixture/etc/default/grub" || fail "x86 GRUB defaults are untouched by the migration"
pass "the GRUB splash migration is a no-op off Apple Silicon"

new_fixture migration-apple
stock_asahi
STUB_APPLE=1 PATH="$stub_bin:$PATH" OMARCHY_PATH="$ROOT" OMARCHY_TEST_CALLS="$calls" \
  OMARCHY_GRUB_DEFAULT="$fixture/etc/default/grub" OMARCHY_GRUB_CFG="$fixture/boot/grub/grub.cfg" \
  OMARCHY_MKINITCPIO_CONF="$fixture/etc/mkinitcpio.conf" OMARCHY_MKINITCPIO_CONF_DIR="$fixture/etc/mkinitcpio.conf.d" \
  OMARCHY_GRUB_SPLASH_PENDING="$fixture/pending" \
  bash -euo pipefail "$migration" >/dev/null
grep -qx 'GRUB_DISTRIBUTOR="Omarchy"' "$fixture/etc/default/grub" || fail "the migration configures GRUB on Apple Silicon"
grep -q '^mkinitcpio -P$' "$calls" || fail "the migration rebuilds the initramfs on Apple Silicon"
pass "the GRUB splash migration runs the leaf on Apple Silicon"
