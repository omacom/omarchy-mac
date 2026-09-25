#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The pacman platform guard keeps this package off other machines, but an entry
# point or service must still re-check the platform when it activates: off Apple
# Silicon each one asks the predicate and stops before touching anything.
mkdir -p "$work/bin" "$work/root" "$work/home" "$work/run" "$work/entry"
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
echo omarchy-hw-apple-silicon >>"$CALLS"
exit 1
STUB
for command in systemctl nmcli pactl pw-dump pw-cli wpctl modprobe journalctl lspci rfkill udevadm busctl sudo; do
  printf '#!/bin/bash\necho %s >>"$CALLS"\n' "$command" >"$work/bin/$command"
done
chmod +x "$work/bin/"*
export CALLS="$work/calls"
for entry in "$ROOT"/bin/*; do
  name=${entry##*/}
  sed "s|/usr/lib/omarchy-mac/|$ROOT/lib/|g" "$entry" >"$work/entry/$name"
  chmod +x "$work/entry/$name"
  args=()
  [[ $name == omarchy-mac-setup-* ]] && args=("$work/root")
  : >"$CALLS"
  status=0
  HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" XDG_STATE_HOME="$work/home/.local/state" \
    XDG_RUNTIME_DIR="$work/run" PATH="$work/bin:$PATH" timeout 10 "$work/entry/$name" "${args[@]}" \
    </dev/null >"$work/out" 2>&1 || status=$?
  (( status == 0 )) || fail "$name exits cleanly off Apple Silicon" "$(cat "$work/out")"
  grep -Fxq omarchy-hw-apple-silicon "$CALLS" || fail "$name checks the platform when it runs"
  ! grep -Fvx omarchy-hw-apple-silicon "$CALLS" >/dev/null || fail "$name stops before acting off Apple Silicon" "$(cat "$CALLS")"
  [[ -z $(find "$work/root" "$work/home" "$work/run" -mindepth 1 -print -quit) ]] || fail "$name writes nothing off Apple Silicon"
done
pass 'every entry point re-checks the platform and stops off Apple Silicon'
for unit in "$ROOT"/vendor/systemd/*/*.service; do
  grep -Eqx 'ExecCondition=/usr/(bin/omarchy-hw-apple-silicon|lib/omarchy-mac/wifi-supported)' "$unit" ||
    fail "${unit##*/} re-checks the platform before it starts"
done
: >"$CALLS"
if PATH="$work/bin:$PATH" "$ROOT/lib/wifi-supported"; then fail 'Wi-Fi support requires Apple Silicon'; fi
[[ $(cat "$CALLS") == omarchy-hw-apple-silicon ]] || fail 'Wi-Fi support asks the platform before probing hardware'
pass 'every service re-checks the platform before it starts'
