#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT/install" "$work/root"
dropin="$work/root/usr/lib/systemd/system/sddm.service.d/10-omarchy-mac-wait-for-display.conf"
wait="$work/root/usr/lib/omarchy-mac/wait-for-display"
grep -qx 'ExecStartPre=-/usr/lib/omarchy-mac/wait-for-display' "$dropin" || fail 'greeter waits through a non-fatal hook'
[[ -x $wait ]] || fail 'greeter wait helper is staged'
pass 'greeter drop-in and helper are staged'

(( EUID != 0 )) || { pass 'fixture roots are ignored as root; behaviour cases skipped'; exit 0; }

mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ ${APPLE:-1} == 1 ]]
STUB
chmod +x "$work/bin/omarchy-hw-apple-silicon"
export PATH="$work/bin:$PATH" OMARCHY_PROC_ROOT="$work/proc" OMARCHY_DEV_ROOT="$work/dev"
node="$work/proc/device-tree/soc/display-subsystem"
card="$work/dev/dri/by-path/platform-soc:display-subsystem-card"
mkdir -p "$node" "${card%/*}"

APPLE=0 timeout 2 "$wait" || fail 'other platforms start the greeter at once'
rmdir "$node"
timeout 2 "$wait" || fail 'a Mac without the display controller starts the greeter at once'
mkdir -p "$node"
touch "$card"
timeout 2 "$wait" || fail 'a ready display controller starts the greeter at once'
pass 'no wait off Apple Silicon, without the controller, or once its card exists'

rm "$card"
"$wait" &
waiter=$!
sleep 0.5
kill -0 "$waiter" 2>/dev/null || fail 'greeter waits for the display controller card'
touch "$card"
for _ in {1..40}; do
  kill -0 "$waiter" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$waiter" 2>/dev/null; then
  kill "$waiter"
  fail 'greeter starts as soon as the display controller card appears'
fi
wait "$waiter" || fail 'the wait never fails the greeter'
pass 'greeter waits for the display controller and starts when its card appears'

stage="$work/root"
user_setup="$stage/usr/bin/omarchy-mac-setup-user"
export HOME="$work/home" XDG_RUNTIME_DIR="$work/no-session"
unset XDG_CONFIG_HOME XDG_STATE_HOME
looknfeel="$HOME/.config/hypr/looknfeel.lua"
marker="$HOME/.local/state/omarchy/mac-cursor-configured"
wants="$HOME/.config/systemd/user/graphical-session.target.wants/omarchy-asahi-mic.service"
software_cursor() {
  if command -v lua >/dev/null; then
    lua - "$looknfeel" <<'LUA'
hl = { config = function(c) software = c.cursor and c.cursor.no_hardware_cursors or software end }
dofile(arg[1])
os.exit(software == true and 0 or 1)
LUA
  else
    grep -q 'no_hardware_cursors = true' "$looknfeel"
  fi
}

"$user_setup" "$stage"
[[ ! -e $marker && -L $wants ]] || fail 'without a Hyprland config the cursor waits and the microphone is still set up'
mkdir -p "${looknfeel%/*}"
printf '%s\n' '-- User look and feel' >"$looknfeel"
APPLE=0 "$user_setup" "$stage"
software_cursor && fail 'other platforms keep the hardware cursor'
"$user_setup" "$stage"
software_cursor || fail 'Apple Silicon draws the cursor in software'
"$user_setup" "$stage"
(( $(grep -c no_hardware_cursors "$looknfeel") == 1 )) || fail 'cursor setup is idempotent'
pass 'Apple Silicon users get a software cursor once'

printf '%s\n' '-- User look and feel' >"$looknfeel"
"$user_setup" "$stage"
software_cursor && fail 'a removed software cursor stays removed'
rm "$marker"
printf '%s\n' 'hl.config({ cursor = { no_hardware_cursors = false } })' >"$looknfeel"
"$user_setup" "$stage"
[[ $(<"$looknfeel") == 'hl.config({ cursor = { no_hardware_cursors = false } })' && -f $marker ]] ||
  fail 'an existing cursor choice is kept'
pass 'a removed or existing cursor choice survives repeated setup'
