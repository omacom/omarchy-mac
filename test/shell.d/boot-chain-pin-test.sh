#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export OMARCHY_BOOT_CHAIN_CONF="$work/pacman.d/boot-chain-pin.conf"
export OMARCHY_BOOT_CHAIN_HOOK="$work/pacman.d/hooks/00-boot-chain-pin.hook"
export OMARCHY_BOOT_CHAIN_LIST="$work/boot-chain-pin.list"
export OMARCHY_BOOT_CHAIN_OFF="$work/boot-chain-pin.off"
export OMARCHY_PACMAN_CONFIG="$work/pacman.conf"

source "$ROOT/bin/omarchy-boot-chain-pin"

# Stub libalpm instead of needing root or a real database.
stub_conf="$work/stub-ignorepkg.txt"
stub_pkgs="$work/stub-packages.txt"
stub_owned="$work/stub-owned.txt"
: >"$stub_conf"
: >"$stub_pkgs"
: >"$stub_owned"
pin_pacman_conf_values() { cat "$stub_conf"; }
pin_pacman_query_names() { cat "$stub_pkgs"; }
pin_pacman_owner() {
  if grep -qxF -- "$1" "$stub_owned"; then
    printf '%s\n' "stub: $1 is owned"
    return 0
  fi
  printf 'error: No package owns %s\n' "$1" >&2
  return 1
}
pin_may_write() { return 0; }

list="$OMARCHY_BOOT_CHAIN_LIST"
printf '%s\n' 'linux-aurora*' 'm1n1*' 'gtk+' >"$list"
expected='^(linux-aurora.*|m1n1.*|gtk\+)$'
[[ $(pin_regex) == "$expected" ]] || fail 'globs become one anchored ERE' "$(pin_regex)"
[[ 'linux-aurora-wip' =~ $(pin_regex) ]] || fail 'the ERE matches a kernel variant'
[[ ! 'linux-api-headers' =~ $(pin_regex) ]] || fail 'the ERE skips unrelated packages'
[[ 'gtk+' =~ $(pin_regex) ]] || fail 'a plus sign in a name stays literal'
pass 'globs become one anchored ERE that matches deny names and only those'

rm -f "$list"
[[ $(pin_globs | head -n 1) == 'linux-aurora*' ]] || fail 'defaults used without a list file'
(( $(pin_globs | wc -l) > 5 )) || fail 'default list is populated'
pass 'without a list file the default kernel and bootloader globs apply'

rm -f "$OMARCHY_BOOT_CHAIN_OFF"
if pin_refuse >/dev/null 2>&1; then
  fail 'refuse blocks a transaction without the override'
fi
out=$(pin_refuse 2>&1 || true)
[[ $out == *"$OMARCHY_BOOT_CHAIN_OFF"* ]] || fail 'refuse names the override file' "$out"
touch "$OMARCHY_BOOT_CHAIN_OFF"
if ! pin_refuse; then
  fail 'refuse allows a deliberate change with the override'
fi
rm -f "$OMARCHY_BOOT_CHAIN_OFF"
pass 'refuse blocks transactions until the override file exists'

printf '%s\n' 'linux-aurora*' 'm1n1*' >"$list"
[[ $(pin_render_conf) == 'IgnorePkg = linux-aurora* m1n1*' ]] || fail 'conf renders one IgnorePkg line' "$(pin_render_conf)"
hook=$(pin_render_hook)
grep -qF 'Target = linux-aurora*' <<<"$hook" || fail 'hook lists the globs as Targets' "$hook"
grep -qF 'AbortOnFail' <<<"$hook" || fail 'hook aborts the transaction on failure' "$hook"
grep -qF "$(pin_bin_path) refuse" <<<"$hook" || fail 'hook runs the refuse action' "$hook"
pass 'the drop-in and hook render from the configured globs'

cat >"$OMARCHY_PACMAN_CONFIG" <<'CONF'
[options]
Architecture = auto

[core]
Server = file:///nonexistent
CONF
pin_install
pin_install
[[ -f $OMARCHY_BOOT_CHAIN_CONF ]] || fail 'install writes the IgnorePkg drop-in'
[[ -f $OMARCHY_BOOT_CHAIN_HOOK ]] || fail 'install writes the pacman hook'
(( $(grep -cF "Include = $OMARCHY_BOOT_CHAIN_CONF" "$OMARCHY_PACMAN_CONFIG") == 1 )) ||
  fail 'install inserts the Include exactly once across repeated runs' "$(cat "$OMARCHY_PACMAN_CONFIG")"
[[ $(sed -n '2p' "$OMARCHY_PACMAN_CONFIG") == "Include = $OMARCHY_BOOT_CHAIN_CONF" ]] ||
  fail 'the Include lands inside the options section' "$(cat "$OMARCHY_PACMAN_CONFIG")"
pass 'install writes the drop-in and hook and is idempotent'

pin_globs >"$stub_conf"
: >"$stub_pkgs"
pin_check "$work/boot.bin"
pass 'check passes when no package is installed or owns the boot files'

printf '%s\n' 'm1n1-aurora' >"$stub_pkgs"
out=$(pin_check 2>&1 || true)
grep -qF 'm1n1-aurora' <<<"$out" || fail 'check reports a deny-list package appearing' "$out"
: >"$stub_pkgs"

printf '%s\n' 'grub*' >"$stub_conf"
out=$(pin_check 2>&1 || true)
grep -qF 'IgnorePkg lacks' <<<"$out" || fail 'check reports a glob missing from IgnorePkg' "$out"
pin_globs >"$stub_conf"

printf '%s\n' "$work/boot.bin" >"$stub_owned"
out=$(pin_check "$work/boot.bin" 2>&1 || true)
grep -qF 'a package owns' <<<"$out" || fail 'check reports a package owning a boot file' "$out"
: >"$stub_owned"

rm -f "$OMARCHY_BOOT_CHAIN_HOOK"
out=$(pin_check 2>&1 || true)
grep -qF 'hook missing' <<<"$out" || fail 'check reports a missing hook' "$out"
pin_install >/dev/null 2>&1

touch "$OMARCHY_BOOT_CHAIN_OFF"
out=$(pin_check 2>&1 || true)
grep -qF 'disabled' <<<"$out" || fail 'check reports the override file' "$out"
rm -f "$OMARCHY_BOOT_CHAIN_OFF"
pass 'check fails loudly on an installed deny package, a missing glob, an owned boot file, a missing hook or an override'

if bash "$ROOT/bin/omarchy-boot-chain-pin" nonsense >/dev/null 2>&1; then
  fail 'an unknown subcommand is rejected'
fi
[[ $(bash "$ROOT/bin/omarchy-boot-chain-pin" list | head -n 1) == 'linux-aurora*' ]] ||
  fail 'the list subcommand prints the default globs'
pass 'the command entrypoint answers list and rejects unknown subcommands'

pass 'boot chain pin keeps a package-unowned kernel and bootloader out of pacman transactions'
