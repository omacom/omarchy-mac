#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
# As root the command ignores fixture roots and changes the live system.
(( EUID != 0 )) || fail 'run the keyboard test as a regular user'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ ${APPLE:-1} == 1 ]]
STUB
for command in mkinitcpio omarchy-mac-boot-update; do
  cat >"$work/bin/$command" <<'STUB'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >>"$CALLS"
exit "${REBUILD_STATUS:-0}"
STUB
done
cat >"$work/bin/modprobe" <<'STUB'
#!/bin/bash
[[ $* == -c ]] && printf '%s\n' 'options appledrm show_notch=1' "${MODPROBE_CONFIG:-}"
STUB
chmod +x "$work/bin/"*
stage="$work/root"
export PATH="$work/bin:$PATH" CALLS="$work/calls" OMARCHY_MAC_FIXTURE_ROOT="$stage"
"$ROOT/install" "$stage"
setup="$stage/usr/bin/omarchy-mac-setup-keyboard"
conf="$stage/etc/modprobe.d/hid_apple.conf"
param="$stage/sys/module/hid_apple/parameters/fnmode"
state="$stage/var/lib/omarchy-mac"
legacy="$stage/var/lib/omarchy/migrations"

# Each run starts from a Mac that has not been handed over yet.
reset() {
  rm -rf "$state" "$legacy" "$conf" "$conf.omarchy-mac-retired"
  mkdir -p "${conf%/*}" "${param%/*}"
  printf 'x\n' >"$param"
  : >"$CALLS"
}

! grep -rqs hid_apple "$stage/usr/lib/modprobe.d" || fail 'the package ships no hid_apple option'
pass 'the package leaves hid_apple at the kernel default, so any owner option wins'

reset
"$setup" 2
[[ ! -s $CALLS && $(<"$param") == x ]] || fail 'a Mac without hid_apple.conf needs no rebuild'
for usage in '' 4 '2 3'; do
  # shellcheck disable=SC2086
  if "$setup" $usage 2>/dev/null; then fail "the generated mode is required: '$usage'"; fi
done
pass 'a Mac without hid_apple.conf needs no rebuild, and the generated mode is required'

for mode in 2 1 3; do
  reset
  printf 'options hid_apple fnmode=%s\n' "$mode" >"$conf"
  "$setup" "$mode" >/dev/null
  [[ ! -e $conf && -f $conf.omarchy-mac-retired ]] || fail "the generated fnmode=$mode line retires"
  [[ $(<"$CALLS") == 'mkinitcpio -P' ]] || fail "retiring fnmode=$mode rebuilds the boot image once" "$(cat "$CALLS")"
  [[ $(<"$param") == 3 ]] || fail "the running keyboard switches to the kernel default"
  : >"$CALLS"
  "$setup" "$mode"
  [[ ! -s $CALLS ]] || fail 'a later run does not rebuild again'
done
pass "each fork's generated line retires with one rebuild, and the keyboard switches now"

# fnmode=1 on an mx-mac Mac, or fnmode=2 after either fork's migration, is the owner's.
for spec in '3 1' '1 2' '3 2' '2 1' '2 0'; do
  read -r generated mode <<<"$spec"
  reset
  printf 'options hid_apple fnmode=%s\n' "$mode" >"$conf"
  "$setup" "$generated" >/dev/null
  [[ $(<"$conf") == "options hid_apple fnmode=$mode" && ! -s $CALLS ]] ||
    fail "fnmode=$mode stays where Omarchy generated fnmode=$generated"
done
for owner in 'options hid_apple fnmode=2 swap_opt_cmd=1' '# F-keys first
options hid_apple fnmode=2'; do
  reset
  printf '%s\n' "$owner" >"$conf"
  "$setup" 2 >/dev/null
  [[ $(<"$conf") == "$owner" && ! -s $CALLS ]] || fail "the owner's hid_apple.conf stays: $owner"
done
reset
printf 'options hid_apple fnmode=2\n' >"$work/owner.conf"
ln -s "$work/owner.conf" "$conf"
"$setup" 2 >/dev/null
[[ -L $conf && ! -s $CALLS ]] || fail "the owner's linked hid_apple.conf stays"
reset
printf 'options hid_apple fnmode=2\n' >"$conf"
APPLE=0 "$setup" 2
[[ -f $conf && ! -e $state && ! -s $CALLS ]] || fail 'other hardware is untouched'
pass 'owner lines, files and links, and other hardware are left alone'

# Only the first run decides: a line the owner writes afterwards, or another
# user's migration naming a different generated mode, never retires it.
reset
printf 'options hid_apple fnmode=1\n' >"$conf"
"$setup" 3 >/dev/null
printf 'options hid_apple fnmode=2\n' >"$conf"
"$setup" 2 >/dev/null
"$setup" 1 >/dev/null
[[ $(<"$conf") == 'options hid_apple fnmode=2' && ! -s $CALLS ]] || fail 'later runs leave the owner line alone'
pass 'the first run decides for every later run and user'

# A failed rebuild stays owed; the retry rebuilds although the file is gone.
reset
printf 'options hid_apple fnmode=2\n' >"$conf"
if REBUILD_STATUS=1 "$setup" 2 >/dev/null; then fail 'a failed rebuild is reported'; fi
[[ ! -e $conf && -f $state/keyboard-rebuild-pending && $(<"$param") == x ]] ||
  fail 'a failed rebuild stays pending and leaves the keyboard alone'
: >"$CALLS"
"$setup" 2 >/dev/null
[[ $(<"$CALLS") == 'mkinitcpio -P' && ! -e $state/keyboard-rebuild-pending && $(<"$param") == 3 ]] ||
  fail 'the retry rebuilds, switches the keyboard and clears the marker'
pass 'a failed rebuild is retried with the keyboard switch on the next run'

# A fork migration that failed its rebuild had already written its own line,
# so the stock fnmode=2 is then the owner's.
for spec in '1789132067-initramfs-pending 1' '1790305681-boot-image-pending 3'; do
  read -r marker mode <<<"$spec"
  reset
  install -Dm644 /dev/null "$legacy/$marker"
  printf 'options hid_apple fnmode=%s\n' "$mode" >"$conf"
  "$setup" 2 >/dev/null
  [[ ! -e $conf && $(<"$CALLS") == 'mkinitcpio -P' && ! -e $legacy/$marker ]] ||
    fail "$marker's line retires with one rebuild"
  reset
  install -Dm644 /dev/null "$legacy/$marker"
  printf 'options hid_apple fnmode=2\n' >"$conf"
  MODPROBE_CONFIG='options hid_apple fnmode="2"' "$setup" 2 >/dev/null
  [[ $(<"$conf") == 'options hid_apple fnmode=2' && $(<"$CALLS") == 'mkinitcpio -P' ]] ||
    fail "$marker's owed rebuild runs and keeps the owner's fnmode=2"
  [[ $(<"$param") == 2 && ! -e $legacy/$marker ]] || fail "the owner's mode applies after $marker's rebuild"
done
pass "rebuilds owed by the forks' keyboard migrations run once"

reset
printf 'options hid_apple fnmode=2\n' >"$conf"
MODPROBE_CONFIG='options hid_apple fnmode=1 swap_opt_cmd=1
options hid_apple iso_layout=0 fnmode=0x2' "$setup" 2 >/dev/null
[[ $(<"$param") == 0x2 ]] || fail 'the live switch writes the last configured fnmode as written'
pass 'the live switch follows the configuration the rebuilt image loads'

cat >"$work/bin/omarchy-mac-limine-active" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$work/bin/omarchy-mac-limine-active"
reset
printf 'options hid_apple fnmode=2\n' >"$conf"
"$setup" 2 >/dev/null
[[ $(<"$CALLS") == 'omarchy-mac-boot-update ' ]] || fail 'a Limine Mac rebuilds its UKI' "$(cat "$CALLS")"
pass 'a Limine Mac rebuilds through omarchy-mac-boot-update'
