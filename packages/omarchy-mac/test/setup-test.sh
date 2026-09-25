#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
[[ -z ${PLATFORM_ERROR:-} ]] || { echo "Error: $PLATFORM_ERROR" >&2; exit 1; }
echo "${PLATFORM:-apple-silicon}"
STUB
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ $(omarchy-hw-platform) == "apple-silicon" ]]
STUB
cat >"$work/bin/lspci" <<'STUB'
#!/bin/bash
echo "Broadcom [14e4:${WIFI_ID:-4433}]"
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CALLS"
exit "${SYSTEMCTL_STATUS:-0}"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" CALLS="$work/calls"
stage="$work/root"
"$ROOT/install" "$stage"
setup="$stage/usr/bin/omarchy-mac-setup-system"
unit="$stage/etc/systemd/system/omarchy-wifi-resume-fix.service"
mkdir -p "${unit%/*}"
"$setup" "$stage"
[[ ! -e $unit ]] || fail 'fresh setup uses vendor unit'
grep -q 'enable omarchy-wifi-resume-fix.service' "$CALLS" || fail 'fresh setup enables recovery'
cp "$ROOT/legacy/${unit##*/}" "$unit"
"$setup" "$stage"
[[ ! -e $unit && -f $unit.omarchy-mac-retired ]] || fail 'recognized generated unit retires'
"$setup" "$stage"
# Simulate interruption after backup but before deleting a duplicate generated file.
cp "$ROOT/legacy/${unit##*/}" "$unit"
"$setup" "$stage"
[[ ! -e $unit ]] || fail 'interrupted retirement retries'
printf 'custom service\n' >"$unit"
: >"$CALLS"
"$setup" "$stage"
[[ $(cat "$unit") == 'custom service' && ! -s $CALLS ]] || fail 'custom unit survives setup'
rm "$unit"
ln -s /dev/null "$unit"
"$setup" "$stage"
[[ $(readlink "$unit") == /dev/null && ! -s $CALLS ]] || fail 'mask survives setup'
rm "$unit"
for spec in 'generic 4433' 'qualcomm 4434' 'apple-silicon 0000'; do
  read -r platform wifi <<<"$spec"
  PLATFORM=$platform WIFI_ID=$wifi "$setup" "$stage"
  [[ ! -s $CALLS ]] || fail 'non-Apple and excluded hardware are untouched'
done
rm "$stage/var/lib/omarchy-mac/wifi-configured"
if SYSTEMCTL_STATUS=42 "$setup" "$stage"; then fail 'enable failure must be retryable'; fi
"$setup" "$stage"
pass 'fresh, upgrade, repeated, interrupted, overrides, masks and hardware gates'
# Each fresh root: recovery is enabled for BCM4378, BCM4387 and BCM4388 on Apple Silicon only.
for spec in 'apple-silicon 4425 1' 'apple-silicon 4433 1' 'apple-silicon 4434 1' 'apple-silicon 4488 0' \
  'generic 4433 0' 'generic-aarch64 4434 0' 'qualcomm 4434 0'; do
  read -r platform wifi enabled <<<"$spec"
  fresh="$work/fresh-$platform-$wifi"
  "$ROOT/install" "$fresh"
  : >"$CALLS"
  PLATFORM=$platform WIFI_ID=$wifi "$fresh/usr/bin/omarchy-mac-setup-system" "$fresh"
  if (( enabled )); then
    grep -q 'enable omarchy-wifi-resume-fix.service' "$CALLS" || fail "recovery enabled on $platform $wifi"
    [[ -f $fresh/var/lib/omarchy-mac/wifi-configured ]] || fail "recovery setup recorded on $platform $wifi"
  else
    [[ ! -s $CALLS && ! -e $fresh/var/lib/omarchy-mac ]] || fail "recovery left off on $platform $wifi"
  fi
done
# A detector that cannot decide stops setup before it changes anything.
fresh="$work/fresh-contradiction"
"$ROOT/install" "$fresh"
mkdir -p "$fresh/etc/NetworkManager/conf.d"
cp "$ROOT/legacy/wifi_backend.conf" "$fresh/etc/NetworkManager/conf.d/"
: >"$CALLS"
if PLATFORM_ERROR='contradictory platform identity' "$fresh/usr/bin/omarchy-mac-setup-system" "$fresh" 2>"$work/err"; then
  fail 'a detector failure fails setup'
fi
grep -q 'contradictory platform identity' "$work/err" || fail 'setup reports the detector failure'
[[ -f $fresh/etc/NetworkManager/conf.d/wifi_backend.conf && ! -s $CALLS ]] || fail 'a detector failure changes nothing'
pass 'BCM4378, BCM4387 and BCM4388 on Apple Silicon only, and a detector failure stops setup'
for relative in etc/modprobe.d/asahi-notch.conf etc/NetworkManager/conf.d/wifi_backend.conf; do
  file="$stage/$relative"
  mkdir -p "${file%/*}"
  cp "$ROOT/legacy/${file##*/}" "$file"
  "$setup" "$stage"
  [[ ! -e $file && -f $file.omarchy-mac-retired ]] || fail 'generated config retires'
  printf 'administrator override\n' >"$file"
  "$setup" "$stage"
  [[ $(cat "$file") == 'administrator override' ]] || fail 'modified config survives'
done
# Earlier Apple installs wrote the backend file with a heredoc or printf; both give these bytes.
backend="$stage/etc/NetworkManager/conf.d/wifi_backend.conf"
rm -f "$backend" "$backend.omarchy-mac-retired"
printf '%s\n' '[device]' 'wifi.backend=iwd' >"$backend"
"$setup" "$stage"
[[ ! -e $backend ]] && cmp -s "$backend.omarchy-mac-retired" "$ROOT/legacy/wifi_backend.conf" ||
  fail 'the generated backend file retires with a backup'
cmp -s "$stage/usr/lib/NetworkManager/conf.d/20-omarchy-mac-wifi.conf" "$ROOT/legacy/wifi_backend.conf" ||
  fail 'the vendor default keeps the retired setting'
# Any edit, even one that keeps iwd, is the administrator's file now.
for variant in '[device]\nwifi.backend=wpa_supplicant\n' '[device]\nwifi.backend=iwd\nwifi.scan-rand-mac-address=no\n' \
  '# keep iwd\n[device]\nwifi.backend=iwd\n' '[device]\nwifi.backend=iwd'; do
  rm -f "$backend"
  printf '%b' "$variant" >"$backend"
  cp "$backend" "$work/expected"
  "$setup" "$stage"
  cmp -s "$backend" "$work/expected" || fail 'an edited backend file survives setup' "$variant"
done
rm "$backend"
ln -s "$stage/usr/share/omarchy-mac/legacy/wifi_backend.conf" "$backend"
"$setup" "$stage"
[[ -L $backend ]] || fail 'a linked backend file survives setup'
rm "$backend"
# A backup the administrator changed is never overwritten; setup stops and says why.
printf 'administrator backup\n' >"$backend.omarchy-mac-retired"
cp "$ROOT/legacy/wifi_backend.conf" "$backend"
if "$setup" "$stage" 2>"$work/err"; then fail 'a changed backup blocks retirement'; fi
grep -q 'wifi_backend.conf.omarchy-mac-retired' "$work/err" || fail 'a blocked retirement names the backup'
[[ $(cat "$backend.omarchy-mac-retired") == 'administrator backup' ]] && cmp -s "$backend" "$ROOT/legacy/wifi_backend.conf" ||
  fail 'a blocked retirement keeps both files'
rm "$backend" "$backend.omarchy-mac-retired"
pass 'the legacy backend file retires only unmodified and never loses an administrator edit'
user_setup="$stage/usr/bin/omarchy-mac-setup-user"
export XDG_RUNTIME_DIR="$work/no-session"
unset XDG_CONFIG_HOME XDG_STATE_HOME
for name in alice bob; do
  export HOME="$work/$name"
  policy="$HOME/.config/wireplumber/wireplumber.conf.d/asahi-headset-mic.conf"
  wants="$HOME/.config/systemd/user/graphical-session.target.wants/omarchy-asahi-mic.service"
  : >"$CALLS"
  "$user_setup" "$stage"
  "$user_setup" "$stage"
  [[ -L $wants && ! -s $CALLS && ! -e $policy ]] || fail 'offline setup needs no bus or private policy'
  mkdir -p "${policy%/*}"
  cp "$ROOT/legacy/asahi-headset-mic.conf" "$policy"
  "$user_setup" "$stage"
  [[ ! -e $policy && -f $policy.omarchy-mac-retired ]] || fail 'generated user policy retires'
  printf 'custom policy\n' >"$policy"
  "$user_setup" "$stage"
  [[ $(cat "$policy") == 'custom policy' ]] || fail 'custom user policy survives'
  rm "$policy"
  ln -s /missing-custom-target "$policy"
  "$user_setup" "$stage"
  [[ -L $policy ]] || fail 'dangling policy override survives'
done
for scope in "$HOME/.config/systemd/user" "$stage/etc/systemd/user"; do
  mkdir -p "$scope"
  rm -f "$wants"
  ln -s /dev/null "$scope/omarchy-asahi-mic.service"
  "$user_setup" "$stage"
  [[ ! -e $wants && ! -L $wants ]] || fail 'user and global masks remain disabled'
  rm "$scope/omarchy-asahi-mic.service"
  echo custom >"$scope/omarchy-asahi-mic.service"
  "$user_setup" "$stage"
  [[ ! -L $wants ]] || fail 'custom user fragment is left alone'
  rm "$scope/omarchy-asahi-mic.service"
done
ln -s /dev/null "$wants"
"$user_setup" "$stage"
[[ $(readlink "$wants") == /dev/null ]] || fail 'activation mask survives'
pass 'multiple users, offline setup, generated policy, custom fragments and masks'
# First-session activation and activation failures use a real fake bus socket.
python3 - "$user_setup" "$stage" "$work" <<'PY'
import os, socket, subprocess, sys
from pathlib import Path
setup, stage, work = sys.argv[1:]
# Redirect filesystem paths while exercising the default live-session branch.
script = Path(work)/'session-setup'
script.write_text(Path(setup).read_text().replace('$root/usr/', stage+'/usr/').replace('$root/etc/', stage+'/etc/').replace('$root/run/', stage+'/run/'))
script.chmod(0o755)
setup = str(script)
env = dict(os.environ, HOME=work+'/session', XDG_RUNTIME_DIR=work+'/runtime')
Path(env['XDG_RUNTIME_DIR']).mkdir()
with socket.socket(socket.AF_UNIX) as bus:
    bus.bind(env['XDG_RUNTIME_DIR']+'/bus')
    subprocess.run([setup], env=env, check=True)
    calls = Path(env['CALLS']).read_text()
    assert '--user daemon-reload' in calls and '--user start omarchy-asahi-mic.service' in calls
    result = subprocess.run([setup], env=dict(env, SYSTEMCTL_STATUS='42'))
    assert result.returncode == 42
PY
pass 'first-session activation errors remain retryable'

# An explicit disable after successful setup remains a choice on later runs.
rm "$wants"
"$user_setup" "$stage"
[[ ! -L $wants ]] || fail 'repeat setup preserves disabled microphone service'
: >"$CALLS"
"$setup" "$stage"
[[ ! -s $CALLS ]] || fail 'repeat setup does not reenable disabled Wi-Fi recovery'
pass 'explicit disables survive repeated setup'
