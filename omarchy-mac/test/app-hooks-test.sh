#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
# post-install and pre-remove, the app hooks omarchy-lifecycle-dispatch runs
# as the user around browser and Steam installs.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/root"
"$ROOT/install" "$stage"
for entry in post-install pre-remove; do
  [[ -x $stage/usr/lib/omarchy/mac/$entry && $(stat -c %a "$stage/usr/lib/omarchy/mac/$entry") == 755 ]] ||
    fail "the $entry entrypoint is staged for omarchy-lifecycle-dispatch"
done
pass 'the app hook entrypoints are staged'

(( EUID != 0 )) || { pass 'fixture roots are ignored as root; behaviour cases skipped'; exit 0; }

mkdir -p "$work/bin" "$work/home"
for command in sudo omarchy-pkg-drop omarchy-launch-steam omarchy-hw-platform; do
  case $command in
    sudo) body='echo "sudo $*" >>"$CALLS"; "$@"' ;;
    omarchy-hw-platform) body='echo apple-silicon' ;;
    *) body='echo "${0##*/} $*" >>"$CALLS"; exit "${FAIL_STATUS:-0}"' ;;
  esac
  printf '#!/bin/bash\n%s\n' "$body" >"$work/bin/$command"
done
cat >"$work/bin/pacman" <<'STUB'
#!/bin/bash
echo "pacman $*" >>"$CALLS"
[[ $1 != "-Q" ]] || [[ " ${INSTALLED:-} " == *" $2 "* ]]
STUB
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" CALLS="$work/calls" HOME="$work/home" OMARCHY_MAC_ROOT="$stage" XDG_RUNTIME_DIR="$work/no-session"
unset XDG_CONFIG_HOME XDG_STATE_HOME
post=$stage/usr/lib/omarchy/mac/post-install
pre=$stage/usr/lib/omarchy/mac/pre-remove

flags=$HOME/.config/brave-flags.conf
mkdir -p "${flags%/*}"
printf '%s\n' '--ozone-platform=wayland' >"$flags"
"$post" brave >/dev/null
grep -Fxq -- '--disable-features=AcceleratedVideoDecoder' "$flags" || fail "a Chromium-family browser's fresh flags turn hardware decode off" "$(cat "$flags")"
for browser in chromium chrome edge brave-origin; do
  "$post" "$browser" >/dev/null || fail "post-install $browser runs the Mac user setup"
done
: >"$CALLS"
for app in firefox zen something-else; do
  "$post" "$app" || fail "post-install $app has nothing to do"
done
[[ ! -s $CALLS ]] || fail 'other apps need nothing' "$(cat "$CALLS")"
mkdir -p "$work/xdg"
printf '%s\n' '--ozone-platform=wayland' >"$HOME/.config/chrome-flags.conf"
XDG_CONFIG_HOME="$work/xdg" "$post" chrome >/dev/null
grep -Fxq -- '--disable-features=AcceleratedVideoDecoder' "$HOME/.config/chrome-flags.conf" ||
  fail "the flags an installer wrote in ~/.config are patched with another XDG_CONFIG_HOME" "$(cat "$HOME/.config/chrome-flags.conf")"
pass "post-install gives a Chromium-family browser the Mac's decode flags, and other apps nothing"

: >"$CALLS"
INSTALLED="steam" "$post" steam >/dev/null
[[ $(grep -v '^pacman -Q' "$CALLS") == $'sudo '"$stage"$'/usr/lib/omarchy-mac/steam-launcher\npacman -S --needed --noconfirm omarchy-steam-fex\nomarchy-launch-steam --prepare' ]] ||
  fail 'post-install steam adds the FEX launcher through sudo, then prepares it' "$(cat "$CALLS")"
if FAIL_STATUS=1 INSTALLED="steam omarchy-steam-fex" "$post" steam >/dev/null 2>&1; then fail 'a failed prepare fails the install'; fi
printf '#!/bin/bash\nexit 1\n' >"$work/bin/sudo"
: >"$CALLS"
if INSTALLED="steam" "$post" steam >/dev/null 2>&1; then fail 'a launcher install that sudo refused fails the install'; fi
! grep -q '^omarchy-launch-steam' "$CALLS" || fail 'nothing is prepared without the launcher'
printf '#!/bin/bash\necho "sudo $*" >>"$CALLS"; "$@"\n' >"$work/bin/sudo"
pass 'post-install steam installs the FEX launcher through sudo and prepares it, failing with either'

desktop=$HOME/.local/share/applications/steam.desktop
mkdir -p "${desktop%/*}"
printf '[Desktop Entry]\nExec=omarchy-launch-steam %%U\n' >"$desktop"
mkdir -p "$HOME/.local/share/fex-steam/steam-launcher"
: >"$CALLS"
"$pre" steam
[[ $(<"$CALLS") == 'omarchy-pkg-drop omarchy-steam-fex' && ! -e $desktop && ! -e $HOME/.local/share/fex-steam ]] ||
  fail "pre-remove steam drops the launcher, the desktop entry it wrote and FEX's Steam client" "$(cat "$CALLS")"
printf '[Desktop Entry]\nExec=my-steam %%U\n' >"$desktop"
"$pre" steam
[[ -f $desktop ]] || fail "a steam.desktop the user changed stays"
: >"$CALLS"
"$pre" firefox
[[ ! -s $CALLS ]] || fail 'other apps have nothing to undo'
if FAIL_STATUS=1 "$pre" steam 2>/dev/null; then fail 'a failed launcher removal stops the removal'; fi
pass 'pre-remove steam drops the FEX launcher and its desktop entry, keeping a changed one'

for entry in "$post" "$pre"; do
  for arguments in '' 'steam extra'; do
    status=0
    # shellcheck disable=SC2086
    "$entry" $arguments 2>/dev/null || status=$?
    (( status == 2 )) || fail "${entry##*/} takes exactly one app: '$arguments'"
  done
done
printf '#!/bin/bash\nexit 1\n' >"$work/bin/omarchy-hw-apple-silicon"
: >"$CALLS"
INSTALLED="steam" "$post" steam
"$pre" steam
[[ ! -s $CALLS ]] || fail 'off Apple Silicon the Steam hooks do nothing' "$(cat "$CALLS")"
pass 'the app hooks take exactly one app, and the Steam ones re-check the platform'
