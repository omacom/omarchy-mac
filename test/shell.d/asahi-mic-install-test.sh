#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
home="$test_tmp/home"
runtime="$test_tmp/runtime"
calls="$test_tmp/calls"
mkdir -p "$stub_bin" "$home" "$runtime"
: >"$calls"

cat >"$stub_bin/omarchy-hw-apple" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$stub_bin/omarchy-audio-asahi-mic-map" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$stub_bin/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$CALLS"
if [[ $1 == --user && -z ${XDG_RUNTIME_DIR:-} ]]; then
  echo "Failed to connect to user scope bus via local transport: \$DBUS_SESSION_BUS_ADDRESS and \$XDG_RUNTIME_DIR not defined" >&2
  exit 1
fi
exit 0
SH

chmod +x "$stub_bin"/*

run_mic() {
  : >"$calls"
  HOME="$home" OMARCHY_PATH="$ROOT" CALLS="$calls" PATH="$stub_bin:$PATH" \
    bash -eE -c 'source "$1"' bash "$ROOT/install/user/hardware/apple/mic.sh"
}

# The guided --resume path: owner is logged in on tty1, sudo -i cleared
# XDG_RUNTIME_DIR, but /run/user/$UID/bus exists. Skip the user-bus call.
unset XDG_RUNTIME_DIR || true
run_mic
if grep -q '^systemctl' "$calls"; then
  fail "mic setup does not call systemctl --user without XDG_RUNTIME_DIR" "$(cat "$calls")"
fi
pass "mic setup defers the user unit when XDG_RUNTIME_DIR is unset"

touch "$runtime/bus"
# Sockets are what the guard looks for; a regular file is not -S.
rm -f "$runtime/bus"
python3 - "$runtime/bus" <<'PY'
import os, socket, sys
path = sys.argv[1]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(path)
PY

XDG_RUNTIME_DIR="$runtime" run_mic
grep -Fx 'systemctl --user daemon-reload' "$calls" >/dev/null ||
  fail "mic setup reloads the user manager when the session bus is reachable"
grep -Fx 'systemctl --user start omarchy-asahi-mic.service' "$calls" >/dev/null ||
  fail "mic setup starts the mapper when the session bus is reachable"
pass "mic setup starts the mapper when XDG_RUNTIME_DIR points at the session bus"

XDG_RUNTIME_DIR="$test_tmp/missing-runtime" run_mic
if grep -q '^systemctl' "$calls"; then
  fail "mic setup does not call systemctl --user without a bus socket" "$(cat "$calls")"
fi
pass "mic setup skips systemctl when XDG_RUNTIME_DIR has no bus"
