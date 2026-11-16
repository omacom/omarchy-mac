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
export OMARCHY_BOOT_CHAIN_BIN="$work/omarchy-boot-chain-pin"
: >"$OMARCHY_BOOT_CHAIN_BIN"
chmod +x "$OMARCHY_BOOT_CHAIN_BIN"

source "$ROOT/bin/omarchy-boot-chain-pin"

# Stub libalpm instead of needing root or a real database.
stub_conf="$work/stub-ignorepkg.txt"
stub_pkgs="$work/stub-packages.txt"
stub_owned="$work/stub-owned.txt"
: >"$stub_conf"
: >"$stub_pkgs"
: >"$stub_owned"
stub_hookdir="$work/stub-hookdir.txt"
printf '%s/\n' "$(dirname "$OMARCHY_BOOT_CHAIN_HOOK")" >"$stub_hookdir" # pacman-conf prints HookDir with a trailing slash
pin_pacman_conf_values() {
  case ${1:-IgnorePkg} in
    HookDir) cat "$stub_hookdir" ;;
    *) cat "$stub_conf" ;;
  esac
}
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
out=$(pin_refuse 2>&1) && fail 'refuse blocks a transaction without the override' "$out"
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
: >"$work/boot.bin"
pin_check "$work/boot.bin"
pass 'check passes when no package is installed or owns the boot files'

printf '%s\n' 'm1n1-aurora' >"$stub_pkgs"
out=$(pin_check 2>&1) && fail 'check fails when a deny-list package is installed' "$out"
grep -qF 'm1n1-aurora' <<<"$out" || fail 'check reports a deny-list package appearing' "$out"
: >"$stub_pkgs"

printf '%s\n' 'grub*' >"$stub_conf"
out=$(pin_check 2>&1) && fail 'check fails when IgnorePkg lacks a glob' "$out"
grep -qF 'IgnorePkg lacks' <<<"$out" || fail 'check reports a glob missing from IgnorePkg' "$out"
pin_globs >"$stub_conf"

printf '%s\n' "$work/boot.bin" >"$stub_owned"
out=$(pin_check "$work/boot.bin" 2>&1) && fail 'check fails when a package owns a boot file' "$out"
grep -qF 'a package owns' <<<"$out" || fail 'check reports a package owning a boot file' "$out"
: >"$stub_owned"

rm -f "$OMARCHY_BOOT_CHAIN_HOOK"
out=$(pin_check 2>&1) && fail 'check fails when the hook is missing' "$out"
grep -qF 'hook missing' <<<"$out" || fail 'check reports a missing hook' "$out"
pin_install >/dev/null 2>&1

touch "$OMARCHY_BOOT_CHAIN_OFF"
out=$(pin_check 2>&1) && fail 'check fails under the override file' "$out"
grep -qF 'disabled' <<<"$out" || fail 'check reports the override file' "$out"
rm -f "$OMARCHY_BOOT_CHAIN_OFF"
pass 'check fails loudly on an installed deny package, a missing glob, an owned boot file, a missing hook or an override'

# An empty or comments-only custom list must fail closed: pinning nothing while reporting healthy is the worst outcome.
for contents in '# nothing pinned' ''; do
  printf '%s\n' "$contents" >"$list"
  for action in pin_install pin_check; do
    out=$("$action" 2>&1) && fail "$action refuses a list with no globs" "$out"
    grep -qF 'no globs' <<<"$out" || fail "$action says why it refuses an empty list" "$out"
  done
done
rm -f "$list"
pass 'an empty or comments-only custom list fails closed instead of pinning nothing'

# install must put an active Include in [options] and say so when it cannot.
active_includes() { awk -v want="Include = $OMARCHY_BOOT_CHAIN_CONF" '$0 == want { n++ } END { print n + 0 }' "$OMARCHY_PACMAN_CONFIG"; }
printf '%s\n' '[options]' "#Include = $OMARCHY_BOOT_CHAIN_CONF" 'Architecture = auto' >"$OMARCHY_PACMAN_CONFIG"
pin_install
[[ $(active_includes) == 1 ]] || fail 'a commented-out Include does not count as installed' "$(cat "$OMARCHY_PACMAN_CONFIG")"
printf '%s\n' '[core]' 'Server = file:///nonexistent' >"$OMARCHY_PACMAN_CONFIG"
out=$(pin_install 2>&1) && fail 'install fails when pacman.conf has no [options] section' "$out"
grep -qF '[options]' <<<"$out" || fail 'install names the missing [options] section' "$out"
[[ $(active_includes) == 0 ]] || fail 'a failed install leaves no Include behind' "$(cat "$OMARCHY_PACMAN_CONFIG")"
pass 'install ignores a commented-out Include and fails loudly without an [options] section'

# Green baseline first, so each failure case below is attributable to its own defect.
printf '%s\n' '[options]' 'Architecture = auto' '' '[core]' 'Server = file:///nonexistent' >"$OMARCHY_PACMAN_CONFIG"
pin_install
pin_globs >"$stub_conf"
: >"$stub_pkgs"
: >"$stub_owned"
pin_check "$work/boot.bin" || fail 'baseline: a fresh install passes check'

# A hook that lost AbortOnFail still contains the command text; check must compare the whole hook.
sed -i '/^AbortOnFail$/d' "$OMARCHY_BOOT_CHAIN_HOOK"
out=$(pin_check 2>&1) && fail 'check fails on a hook without AbortOnFail' "$out"
grep -qF 'hook missing or wrong' <<<"$out" || fail 'check names a hook that lost AbortOnFail' "$out"
pin_install
chmod -x "$OMARCHY_BOOT_CHAIN_BIN"
out=$(pin_check 2>&1) && fail 'check fails when the hook command is not executable' "$out"
grep -qF 'not executable' <<<"$out" || fail 'check names the non-executable hook command' "$out"
chmod +x "$OMARCHY_BOOT_CHAIN_BIN"
pass 'check fails on a hook that differs from the rendered one or points at a command that cannot run'

# A failed package query must not look like a clean machine.
pin_pacman_query_names() { return 1; }
out=$(pin_check 2>&1) && fail 'check fails when the installed package list cannot be read' "$out"
grep -qF 'could not read the installed package list' <<<"$out" || fail 'check says the package query failed' "$out"
pin_pacman_query_names() { cat "$stub_pkgs"; }

# A path that does not exist, or an owner query that errors, is not "owned by nobody".
out=$(pin_check "$work/no-such-file" 2>&1) && fail 'check fails on a path that does not exist' "$out"
grep -qF 'does not exist' <<<"$out" || fail 'check names the missing path' "$out"
pin_pacman_owner() { printf 'error: failed to read the database\n' >&2; return 1; }
out=$(pin_check "$work/boot.bin" 2>&1) && fail 'check fails when the owner query errors' "$out"
grep -qF 'could not query the owner' <<<"$out" || fail 'check says the owner query failed' "$out"
pin_pacman_owner() {
  if grep -qxF -- "$1" "$stub_owned"; then
    printf '%s\n' "stub: $1 is owned"
    return 0
  fi
  printf 'error: No package owns %s\n' "$1" >&2
  return 1
}
pass 'check fails on a missing path, an unreadable package list and an owner query that errors'

# Custom list parsing: trim, a last line with no newline, unsupported globs, unreadable file.
printf '  grub*  # keep local loader\nm1n1*' >"$list"
[[ $(pin_globs | paste -sd, -) == 'grub*,m1n1*' ]] || fail 'list entries are trimmed and a last line without a newline counts' "$(pin_globs)"
grep -qxF 'Target = m1n1*' <<<"$(pin_render_hook)" || fail 'the last list line becomes a hook Target' "$(pin_render_hook)"
for bad_glob in 'linux-asahi?' 'linux-[ab]' '!grub'; do
  printf '%s\n' "$bad_glob" >"$list"
  for action in pin_install pin_check; do
    out=$("$action" 2>&1) && fail "$action refuses the unsupported glob $bad_glob" "$out"
    grep -qF 'unsupported glob' <<<"$out" || fail "$action names the unsupported glob $bad_glob" "$out"
  done
done
printf '%s\n' 'grub*' >"$list"
chmod 000 "$list"
if [[ ! -r $list ]]; then # root reads a mode 000 file, so the check only runs for a normal user
  for action in pin_install pin_check; do
    out=$("$action" 2>&1) && fail "$action refuses an unreadable list" "$out"
    grep -qF 'not readable' <<<"$out" || fail "$action says the list is unreadable" "$out"
  done
fi
chmod 644 "$list"
rm -f "$list"
pass 'custom lists are trimmed, keep a last line with no newline, and reject unsupported or unreadable input'

# An Include under another section does not count; install must still add one under [options].
printf '%s\n' '[options]' 'Architecture = auto' '[core]' "Include = $OMARCHY_BOOT_CHAIN_CONF" >"$OMARCHY_PACMAN_CONFIG"
pin_has_include "$OMARCHY_PACMAN_CONFIG" "$OMARCHY_BOOT_CHAIN_CONF" && fail 'an Include under [core] counts as installed' "$(cat "$OMARCHY_PACMAN_CONFIG")"
pin_install
pin_has_include "$OMARCHY_PACMAN_CONFIG" "$OMARCHY_BOOT_CHAIN_CONF" || fail 'install adds the Include under [options]' "$(cat "$OMARCHY_PACMAN_CONFIG")"
[[ $(sed -n '2p' "$OMARCHY_PACMAN_CONFIG") == "Include = $OMARCHY_BOOT_CHAIN_CONF" ]] || fail 'the new Include lands right under [options]' "$(cat "$OMARCHY_PACMAN_CONFIG")"
pass 'an Include in another section does not count as installed'

# Second review round: HookDir, /etc/omarchy, --config, pacman.conf handling.
reset_conf() { rm -rf "$OMARCHY_PACMAN_CONFIG" "$OMARCHY_PACMAN_CONFIG.bak"; printf '%s\n' '[options]' 'Architecture = auto' '' '[core]' 'Server = file:///nonexistent' >"$OMARCHY_PACMAN_CONFIG"; }
reset_conf
rm -f "$list"
pin_install
pin_globs >"$stub_conf"
: >"$stub_pkgs"
: >"$stub_owned"
pin_check "$work/boot.bin" || fail 'baseline two: a fresh install passes check'

# check must confirm that pacman actually loads the hook directory.
printf '%s\n' '/etc/somewhere/else/' >"$stub_hookdir"
out=$(pin_check 2>&1) && fail 'check fails when HookDir does not include the hook directory' "$out"
grep -qF 'HookDir' <<<"$out" || fail 'check names HookDir when the hook would not load' "$out"
printf '%s/\n' "$(dirname "$OMARCHY_BOOT_CHAIN_HOOK")" >"$stub_hookdir"
pin_check "$work/boot.bin" || fail 'check passes again when HookDir lists the hook directory'
pass 'check confirms the hook directory is one pacman loads'

# The refuse message tells the user to touch a file under /etc/omarchy, so install must create that directory.
rm -rf "$work/newdir"
OMARCHY_BOOT_CHAIN_OFF="$work/newdir/boot-chain-pin.off" pin_install
[[ -d $work/newdir ]] || fail 'install creates the directory of the override file'
pass 'install creates the directory the override file lives in'

# The libalpm queries must read the same pacman.conf that install edits.
fakebin="$work/fakebin"
mkdir -p "$fakebin"
for tool in pacman pacman-conf; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >>"%s/calls.log"\n' "$tool" "$work" >"$fakebin/$tool"
  chmod +x "$fakebin/$tool"
done
: >"$work/calls.log"
(
  PATH="$fakebin:$PATH"
  # shellcheck disable=SC1090
  source "$ROOT/bin/omarchy-boot-chain-pin"
  pin_pacman_conf_values IgnorePkg
  pin_pacman_query_names
  pin_pacman_owner /boot/x
) >/dev/null
for call in 'pacman-conf --config' 'pacman --config'; do
  (( $(grep -cF "$call $OMARCHY_PACMAN_CONFIG" "$work/calls.log") >= 1 )) || fail "the queries pass $call to pacman" "$(cat "$work/calls.log")"
done
(( $(grep -c -- "--config $OMARCHY_PACMAN_CONFIG" "$work/calls.log") == 3 )) || fail 'all three queries pass --config' "$(cat "$work/calls.log")"
pass 'the pacman queries pass --config for the configured pacman.conf'

# A pacman.conf with no [options] section: install changes nothing, not even the drop-in and hook.
printf '%s\n' '[core]' 'Server = file:///nonexistent' >"$OMARCHY_PACMAN_CONFIG"
cp "$OMARCHY_PACMAN_CONFIG" "$work/pacman.conf.before"
rm -f "$OMARCHY_BOOT_CHAIN_CONF" "$OMARCHY_BOOT_CHAIN_HOOK" "$OMARCHY_PACMAN_CONFIG.bak"
out=$(pin_install 2>&1) && fail 'install fails when pacman.conf has no [options] section' "$out"
[[ ! -e $OMARCHY_BOOT_CHAIN_CONF && ! -e $OMARCHY_BOOT_CHAIN_HOOK ]] || fail 'a failed install leaves the drop-in and hook behind'
cmp -s "$OMARCHY_PACMAN_CONFIG" "$work/pacman.conf.before" || fail 'a failed install leaves pacman.conf untouched' "$(cat "$OMARCHY_PACMAN_CONFIG")"
[[ ! -e $OMARCHY_PACMAN_CONFIG.bak ]] || fail 'a failed install makes no backup'
grep -qF 'nothing was written' <<<"$out" || fail 'the failure says nothing was written' "$out"
pass 'install without an [options] section writes nothing and says so'

# pacman.conf is edited in place: a symlink stays a symlink, the mode survives and a backup is kept.
reset_conf
mv "$OMARCHY_PACMAN_CONFIG" "$work/real-pacman.conf"
chmod 600 "$work/real-pacman.conf"
ln -s "$work/real-pacman.conf" "$OMARCHY_PACMAN_CONFIG"
pin_install
[[ -L $OMARCHY_PACMAN_CONFIG ]] || fail 'install keeps pacman.conf a symlink'
[[ $(stat -c %a "$work/real-pacman.conf") == 600 ]] || fail 'install keeps the pacman.conf mode' "$(stat -c %a "$work/real-pacman.conf")"
pin_has_include "$work/real-pacman.conf" "$OMARCHY_BOOT_CHAIN_CONF" || fail 'install edits the file the symlink points at'
[[ -f $work/real-pacman.conf.bak ]] || fail 'install backs pacman.conf up before the edit'
pin_has_include "$work/real-pacman.conf.bak" "$OMARCHY_BOOT_CHAIN_CONF" && fail 'the backup is the file as it was before the edit'
rm -f "$OMARCHY_PACMAN_CONFIG" "$work/real-pacman.conf" "$work/real-pacman.conf.bak"
pass 'install keeps a symlinked pacman.conf and its mode and leaves a backup'

# When the edit itself fails after the drop-in and hook are written, say what is already in place and how to remove it.
reset_conf
if [[ $(id -u) != 0 ]]; then
  mkdir -p "$work/ro"
  mv "$OMARCHY_PACMAN_CONFIG" "$work/ro/pacman.conf"
  chmod 555 "$work/ro"
  ln -s "$work/ro/pacman.conf" "$OMARCHY_PACMAN_CONFIG"
  out=$(pin_install 2>&1) && fail 'install fails when pacman.conf cannot be rewritten' "$out"
  grep -qF 'already in place' <<<"$out" || fail 'the failure says the hook is already in place' "$out"
  grep -qF "rm " <<<"$out" || fail 'the failure says how to remove the hook' "$out"
  chmod 755 "$work/ro"
  rm -f "$OMARCHY_PACMAN_CONFIG"
fi
pass 'a failed pacman.conf edit says the hook is in place and how to remove it'

if bash "$ROOT/bin/omarchy-boot-chain-pin" nonsense >/dev/null 2>&1; then
  fail 'an unknown subcommand is rejected'
fi
[[ $(bash "$ROOT/bin/omarchy-boot-chain-pin" list | head -n 1) == 'linux-aurora*' ]] ||
  fail 'the list subcommand prints the default globs'
pass 'the command entrypoint answers list and rejects unknown subcommands'

pass 'boot chain pin keeps a package-unowned kernel and bootloader out of pacman transactions'
