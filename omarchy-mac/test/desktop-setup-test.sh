#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The Apple desktop setup omarchy-mac took over from the runtime's leaves: the
# lifecycle entrypoints, the pacman templates, the Electron wrappers and
# desktop entries, the trackpad defaults and the browser decode flags.
stage="$work/root"
"$ROOT/install" "$stage"
for entry in setup-system setup-user; do
  [[ -x $stage/usr/lib/omarchy/mac/$entry && $(stat -c %a "$stage/usr/lib/omarchy/mac/$entry") == 755 ]] ||
    fail "the $entry entrypoint is staged for omarchy-lifecycle-dispatch"
done
for channel in stable rc edge; do
  template=$stage/usr/share/omarchy-mac/pacman/pacman-$channel.conf
  grep -qx '\[asahi-alarm\]' "$template" && grep -qx '\[omarchy\]' "$template" ||
    fail "the Apple $channel pacman template is staged with [asahi-alarm] and [omarchy]"
done
[[ -x $stage/usr/bin/omarchy-hw-apple && $(readlink "$stage/usr/share/omarchy/bin/omarchy-hw-apple") == /usr/bin/omarchy-hw-apple ]] ||
  fail 'the legacy alias is staged in /usr/bin and linked from the runtime tree'
platform=$stage/usr/share/omarchy-platform
for file in hypr/defaults/apple.lua hypr/settings/apple.lua hypr/gestures/apple-gestures.lua key-names display-cutouts.json displays.conf keyrings audio.json; do
  [[ -f $platform/$file && ! -L $platform/$file ]] || fail "$file is staged in the platform root"
done
[[ $(grep -v '^#' "$platform/keyrings") == asahi-alarm-keyring ]] ||
  fail 'the platform names the [asahi-alarm] keyring for omarchy update to refresh'
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$platform/display-cutouts.json" ||
  fail 'the cutout description is valid JSON'
# A runtime older than the platform root reads the same files from its own tree.
while read -r file legacy; do
  legacy=$stage/usr/share/omarchy/default/$legacy
  [[ -f $legacy && ! -L $legacy ]] && cmp -s "$platform/$file" "$legacy" ||
    fail "$file is also staged, unchanged, where an older runtime reads it"
done <<'LEGACY'
hypr/defaults/apple.lua hypr/platform/defaults/apple.lua
hypr/settings/apple.lua hypr/platform/settings/apple.lua
hypr/gestures/apple-gestures.lua hypr/platform/apple-gestures.lua
key-names omarchy/platform/key-names
display-cutouts.json shell/platform/display-cutouts.json
LEGACY
# displays.conf follows the runtime's grammar (docs/file-layout.md): one
# directive per line, a name with no "/", comments on whole lines only. Nothing
# in it may be a line the runtime would silently ignore.
directives=()
while IFS= read -r line || [[ -n $line ]]; do
  [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
  read -r directive argument extra <<<"$line"
  case $directive in
  backlight-skip | backlight-prefer)
    [[ -n $argument && -z $extra && $argument != */* && $argument != . && $argument != .. ]] ||
      fail "displays.conf: $directive takes one name" "$line" ;;
  ddc-require-connector-ddc) [[ -z $argument ]] || fail "displays.conf: $directive takes no argument" "$line" ;;
  *) fail 'displays.conf: unknown directive' "$line" ;;
  esac
  directives+=("$directive${argument:+ $argument}")
done <"$platform/displays.conf"
[[ ${directives[*]} == 'backlight-skip display-pipe backlight-skip 228600000.dsi.0 backlight-prefer apple-panel-bl ddc-require-connector-ddc' ]] ||
  fail 'displays.conf skips the Touch Bar backlights, prefers the Retina panel and probes DDC only where a connector has it' "${directives[*]}"
for helper in electron-launchers electron-desktop-entries; do
  [[ -x $stage/usr/lib/omarchy-mac/$helper ]] || fail "$helper is staged"
done
pass 'the setup entrypoints, pacman templates, platform files and Electron helpers are staged'

(( EUID != 0 )) || { pass 'fixture roots are ignored as root; behaviour cases skipped'; exit 0; }

mkdir -p "$work/bin" "$work/apps"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
echo "${PLATFORM:-apple-silicon}"
STUB
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ $(omarchy-hw-platform) == "apple-silicon" ]]
STUB
cat >"$work/bin/lspci" <<'STUB'
#!/bin/bash
echo "Broadcom [14e4:4433]"
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$CALLS"
STUB
# The runtime's Electron helpers: each call is recorded, and the wrapper's
# status for an app comes from WRAP_<APP>.
cat >"$work/bin/omarchy-cmd-electron-gl-wrap" <<'STUB'
#!/bin/bash
printf 'wrap %s\n' "$*" >>"$CALLS"
[[ $1 != "--check" ]] || shift
status=WRAP_${1^^}
exit "${!status:-0}"
STUB
cat >"$work/bin/omarchy-cmd-desktop-exec-repair" <<'STUB'
#!/bin/bash
printf 'repair %s\n' "$*" >>"$CALLS"
STUB
chmod +x "$work/bin/"*
for app in chromium 1password cursor; do
  printf '#!/bin/bash\n' >"$work/apps/$app"
done
chmod +x "$work/apps/"*
export PATH="$work/bin:$PATH" CALLS="$work/calls" HOME="$work/home" XDG_RUNTIME_DIR="$work/no-session"
export OMARCHY_CHROMIUM_BIN="$work/apps/chromium" OMARCHY_1PASSWORD_BIN="$work/apps/1password" OMARCHY_CURSOR_BIN="$work/missing/cursor"
unset XDG_CONFIG_HOME XDG_STATE_HOME
launchers="$stage/usr/lib/omarchy-mac/electron-launchers"
entries="$stage/usr/lib/omarchy-mac/electron-desktop-entries"

: >"$CALLS"
"$launchers" || fail 'the Electron launchers are wrapped'
[[ $(<"$CALLS") == "wrap chromium $work/apps/chromium"$'\n'"wrap 1password $work/apps/1password" ]] ||
  fail 'each installed Electron app is wrapped, a missing one is not' "$(cat "$CALLS")"
: >"$CALLS"
output=$(WRAP_CHROMIUM=3 "$launchers" 2>&1) || fail 'an administrator-owned launcher does not fail setup' "$output"
grep -q 'Preserving administrator-owned chromium launcher' <<<"$output" && grep -q '^wrap 1password' "$CALLS" ||
  fail 'an administrator-owned launcher is kept and the others still wrapped' "$output"
if WRAP_1PASSWORD=1 "$launchers" >/dev/null 2>&1; then fail 'a wrapper that fails fails setup'; fi
mkdir -p "$work/bare"
ln -s "$work/bin/omarchy-hw-platform" "$work/bare/omarchy-hw-platform"
if PATH="$work/bare" "$launchers" >/dev/null 2>&1; then fail 'a runtime without the wrapper helper fails setup'; fi
if PATH="$work/bare" "$entries" >/dev/null 2>&1; then fail 'a runtime without the desktop helpers fails user setup'; fi
pass 'system setup wraps each installed Electron app, keeping administrator-owned launchers, and needs the runtime helpers'

export OMARCHY_CURSOR_BIN="$work/apps/cursor"
applications=$HOME/.local/share/applications
: >"$CALLS"
"$entries" || fail 'the Electron desktop entries are repaired'
grep -Fxq "repair $applications/chromium.desktop /usr/share/applications/chromium.desktop /usr/local/bin/chromium $work/apps/chromium chromium" "$CALLS" &&
  grep -Fxq "repair $applications/cursor-url-handler.desktop /usr/share/applications/cursor-url-handler.desktop /usr/local/bin/cursor $work/apps/cursor cursor" "$CALLS" &&
  (( $(grep -c '^wrap --check' "$CALLS") == 3 && $(grep -c '^repair' "$CALLS") == 4 )) ||
  fail "each ready wrapper's desktop entries point at it" "$(cat "$CALLS")"
: >"$CALLS"
output=$(WRAP_CHROMIUM=4 WRAP_CURSOR=3 "$entries" 2>&1) || fail 'a wrapper that is not ready does not fail setup' "$output"
grep -q 'Skipping chromium desktop repair' <<<"$output" && [[ $(grep -c '^repair' "$CALLS") == 1 ]] ||
  fail "a wrapper that is not ready leaves its desktop entries alone" "$(cat "$CALLS")"
if WRAP_1PASSWORD=1 "$entries" >/dev/null 2>&1; then fail 'a failed wrapper check fails user setup'; fi
pass 'user setup points desktop entries at ready wrappers only'

setup_user="$stage/usr/bin/omarchy-mac-setup-user"
input="$HOME/.config/hypr/input.lua"
: >"$CALLS"
"$setup_user" "$stage"
[[ ! -e $input ]] || fail 'a user without a Hyprland input file gets none'
! grep -q '^wrap\|^repair' "$CALLS" || fail 'a staging root skips the Electron desktop entries'
mkdir -p "${input%/*}"
printf '%s\n' '-- personal overrides' >"$input"
PLATFORM=generic-aarch64 "$setup_user" "$stage"
! grep -q 'omarchy-apple-touchpad' "$input" || fail 'other platforms keep their trackpad defaults'
"$setup_user" "$stage"
grep -Fq 'natural_scroll = true' "$input" && grep -Fq 'tap_to_click = false' "$input" || fail 'Apple trackpads scroll naturally and click physically'
before=$(<"$input")
"$setup_user" "$stage"
[[ $(<"$input") == "$before" ]] || fail 'trackpad setup is idempotent'
printf '%s\n' 'hl.config({' '  input = {' '    touchpad = {' '      natural_scroll = false,' '    },' '  },' '})' >"$input"
before=$(<"$input")
"$setup_user" "$stage"
[[ $(<"$input") == "$before" ]] || fail 'an explicit trackpad choice is preserved' "$(cat "$input")"
pass 'Apple trackpads get natural scrolling and physical clicks once, keeping explicit choices'

flags="$HOME/.config/brave-flags.conf"
printf '%s\n' '--ozone-platform=wayland' >"$flags"
PLATFORM=generic-aarch64 "$setup_user" "$stage"
[[ $(<"$flags") == '--ozone-platform=wayland' ]] || fail 'other platforms keep browser hardware decode'
"$setup_user" "$stage"
[[ $(<"$flags") == $'--ozone-platform=wayland\n--disable-features=AcceleratedVideoDecoder' ]] || fail 'a plain flags file gets the decode workaround' "$(cat "$flags")"
printf '%s' '--ozone-platform=wayland' >"$flags"
"$setup_user" "$stage"
[[ $(<"$flags") == $'--ozone-platform=wayland\n--disable-features=AcceleratedVideoDecoder' ]] ||
  fail 'the workaround goes on its own line without a final newline' "$(cat "$flags")"
printf '%s\n' '--disable-features=SomeOtherThing' '--ozone-platform=wayland' >"$flags"
"$setup_user" "$stage"
"$setup_user" "$stage"
[[ $(<"$flags") == $'--disable-features=SomeOtherThing,AcceleratedVideoDecoder\n--ozone-platform=wayland' ]] ||
  fail 'the workaround joins an existing list once' "$(cat "$flags")"
printf '%s\n' '--disable-features=' >"$flags"
"$setup_user" "$stage"
[[ $(<"$flags") == '--disable-features=AcceleratedVideoDecoder' ]] || fail 'an empty list takes the feature alone' "$(cat "$flags")"
for browser in chromium chrome microsoft-edge-stable brave-origin; do
  printf '%s\n' '--ozone-platform=wayland' >"$HOME/.config/$browser-flags.conf"
done
"$setup_user" "$stage"
for browser in chromium chrome microsoft-edge-stable brave-origin; do
  grep -Fxq -- '--disable-features=AcceleratedVideoDecoder' "$HOME/.config/$browser-flags.conf" || fail "$browser gets the decode workaround"
done
pass 'Chromium-family browsers decode in software on Apple Silicon, once, joining existing lists'

: >"$CALLS"
OMARCHY_MAC_ROOT=$stage "$stage/usr/lib/omarchy/mac/setup-user" || fail 'the setup-user entrypoint runs user setup'
[[ -L $HOME/.config/systemd/user/graphical-session.target.wants/omarchy-asahi-mic.service ]] || fail 'the setup-user entrypoint sets up the microphone'
OMARCHY_MAC_ROOT=$stage "$stage/usr/lib/omarchy/mac/setup-system" image-first-boot || fail 'the setup-system entrypoint runs system setup'
! grep -q '^wrap' "$CALLS" || fail 'a staging root skips the Electron launchers'
env -i PATH="$PATH" CALLS="$CALLS" OMARCHY_MAC_ROOT="$stage" "$stage/usr/lib/omarchy/mac/setup-user" ||
  fail 'the setup-user entrypoint finds the home of a caller that emptied its environment'
grep -q '^systemctl --root=.* enable omarchy-wifi-resume-fix.service' "$CALLS" || fail 'the setup-system entrypoint sets up the Mac services' "$(cat "$CALLS")"
status=0
"$stage/usr/lib/omarchy/mac/setup-system" first-boot 2>/dev/null || status=$?
(( status == 2 )) || fail 'setup-system refuses an unknown argument'
status=0
"$stage/usr/lib/omarchy/mac/setup-user" extra 2>/dev/null || status=$?
(( status == 2 )) || fail 'setup-user takes no argument'
pass 'the lifecycle entrypoints run the Mac system and user setup'

# Steam under FEX: system setup installs the launcher where Steam is, and user
# setup prepares it for a user who has Steam.
steam_launcher="$stage/usr/lib/omarchy-mac/steam-launcher"
[[ -x $steam_launcher ]] || fail 'the Steam launcher step is staged'
cat >"$work/bin/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s OMARCHY_UPDATE_PACMAN=%s\n' "$*" "${OMARCHY_UPDATE_PACMAN:-}" >>"$CALLS"
if [[ $1 == "-Q" ]]; then
  [[ " ${INSTALLED_PACKAGES:-} " == *" $2 "* ]]
else
  exit "${PACMAN_STATUS:-0}"
fi
STUB
cat >"$work/bin/omarchy-launch-steam" <<'STUB'
#!/bin/bash
printf 'omarchy-launch-steam %s\n' "$*" >>"$CALLS"
STUB
chmod +x "$work/bin/pacman" "$work/bin/omarchy-launch-steam"
: >"$CALLS"
"$steam_launcher"
! grep -q '^pacman -S' "$CALLS" || fail 'no Steam, no FEX launcher'
: >"$CALLS"
INSTALLED_PACKAGES="steam" "$steam_launcher" >/dev/null
grep -Fxq 'pacman -S --needed --noconfirm omarchy-steam-fex OMARCHY_UPDATE_PACMAN=1' "$CALLS" ||
  fail 'Steam without the FEX launcher gets it from the repositories' "$(cat "$CALLS")"
: >"$CALLS"
INSTALLED_PACKAGES="steam omarchy-steam-fex" "$steam_launcher"
! grep -q '^pacman -S' "$CALLS" || fail 'an installed launcher is left alone'
if INSTALLED_PACKAGES="steam" PACMAN_STATUS=1 "$steam_launcher" >/dev/null 2>&1; then fail 'a failed launcher install fails setup'; fi
: >"$CALLS"
PLATFORM=generic-aarch64 INSTALLED_PACKAGES="steam" "$steam_launcher"
! grep -q '^pacman' "$CALLS" || fail 'other platforms never get the FEX launcher'
: >"$CALLS"
INSTALLED_PACKAGES="steam" OMARCHY_MAC_SETUP_OFFLINE=1 "$steam_launcher"
! grep -q '^pacman -S' "$CALLS" || fail 'an image first boot, maybe offline, downloads no Steam launcher' "$(cat "$CALLS")"
grep -Fq '"$root/usr/lib/omarchy-mac/steam-launcher"' "$stage/usr/bin/omarchy-mac-setup-system" &&
  grep -Fq 'OMARCHY_MAC_SETUP_OFFLINE="${1:+1}"' "$stage/usr/lib/omarchy/mac/setup-system" ||
  fail 'system setup runs the Steam step, told whether this is an image first boot'
pass 'system setup installs the Steam FEX launcher wherever Steam is, online and only on Apple Silicon'

# User setup's live steps run only without a staging root: a copy reads the
# staged helpers, and the Electron ones see no installed apps.
sed 's|"$root/usr/lib/omarchy-mac/|"'"$stage"'/usr/lib/omarchy-mac/|' "$setup_user" >"$work/setup-user-live"
chmod +x "$work/setup-user-live"
setup_user=$work/setup-user-live
export OMARCHY_CHROMIUM_BIN="$work/missing" OMARCHY_1PASSWORD_BIN="$work/missing" OMARCHY_CURSOR_BIN="$work/missing"
: >"$CALLS"
"$setup_user" >/dev/null
! grep -q '^omarchy-launch-steam' "$CALLS" || fail 'a user without Steam is not prepared for it'
INSTALLED_PACKAGES="steam" "$setup_user" >/dev/null
grep -Fxq 'omarchy-launch-steam --prepare' "$CALLS" || fail "a user on a Mac with Steam installed is prepared for it" "$(cat "$CALLS")"
: >"$CALLS"
mkdir -p "$HOME/.local/share/Steam"
"$setup_user" >/dev/null
grep -Fxq 'omarchy-launch-steam --prepare' "$CALLS" || fail "a user's own Steam is prepared for the FEX launcher" "$(cat "$CALLS")"
pass 'user setup prepares Steam for the FEX launcher where the user has Steam'
