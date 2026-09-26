#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The pacman platform guard keeps this package off other machines, but a command,
# unit helper or udev helper must still re-check the platform when it runs: off
# Apple Silicon each one asks the detector or its Apple predicate and stops
# before touching anything.
mkdir -p "$work/bin" "$work/root" "$work/home" "$work/run" "$work/entry"
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
echo platform >>"$CALLS"
exit 1
STUB
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
echo platform >>"$CALLS"
echo generic-aarch64
STUB
for command in systemctl nmcli pactl pw-dump pw-cli wpctl modprobe journalctl lspci rfkill udevadm busctl sudo tee; do
  printf '#!/bin/bash\necho %s >>"$CALLS"\n' "$command" >"$work/bin/$command"
done
chmod +x "$work/bin/"*
export CALLS="$work/calls"
for entry in "$ROOT"/bin/* "$ROOT"/lib/*; do
  name=${entry##*/}
  sed "s|/usr/lib/omarchy-mac/|$ROOT/lib/|g" "$entry" >"$work/entry/$name"
  chmod +x "$work/entry/$name"
  args=()
  case $name in
    omarchy-mac-setup-keyboard) args=(2) ;;
    omarchy-mac-setup-*) args=("$work/root") ;;
  esac
  : >"$CALLS"
  HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" XDG_STATE_HOME="$work/home/.local/state" \
    XDG_RUNTIME_DIR="$work/run" PATH="$work/bin:$PATH" timeout 10 "$work/entry/$name" "${args[@]}" \
    </dev/null >"$work/out" 2>&1 || true
  grep -Fxq platform "$CALLS" || fail "$name checks the platform when it runs" "$(cat "$work/out")"
  ! grep -Fvx platform "$CALLS" >/dev/null || fail "$name stops before acting off Apple Silicon" "$(cat "$CALLS")"
  [[ -z $(find "$work/root" "$work/home" "$work/run" -mindepth 1 -print -quit) ]] || fail "$name writes nothing off Apple Silicon"
done
pass 'every command and helper re-checks the platform and stops off Apple Silicon'
for unit in "$ROOT"/vendor/systemd/*/*.service; do
  grep -Eqx 'ExecCondition=/usr/(bin/omarchy-hw-apple-silicon|lib/omarchy-mac/wifi-supported)' "$unit" ||
    fail "${unit##*/} re-checks the platform before it starts"
done
pass 'every service re-checks the platform before it starts'
