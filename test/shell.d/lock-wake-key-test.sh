#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Keys never reach the fixture below without a window, so pin the wiring here:
# the wake key is judged before the wake clears displaysBlank, then swallowed.
run_node_test <<'JS'
const fs = require('fs')
const lockView = fs.readFileSync(path.join(root, 'shell/plugins/lock/LockView.qml'), 'utf8')

assert(
  /Keys\.onPressed: function\(event\) \{\s*var wakeKey = root\.isWakeKey\(event\.key, event\.isAutoRepeat\)\s*root\.wakeRequested\(\)\s*if \(wakeKey\) \{\s*event\.accepted = true\s*return\s*\}/.test(lockView),
  'the password field swallows the key that wakes a blank lock'
)

const service = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')
assert(
  /id: resumeWatchTimer[\s\S]*?running: root\.lockRequested[\s\S]*?now - lastTick > interval \+ 2000[\s\S]*?if \(resumed\) \{[\s\S]*?root\.runWake\(\)/.test(service),
  'a resume clears the blank state, so the first key at a lit lock is typed'
)

assert(
  /anyDisplayBlank: root\.anyDisplayBlank/.test(service),
  'every lock surface judges wake keys by whether any panel is dark'
)

assert(
  /function onScreensChanged\(\) \{[\s\S]*?if \(root\.displaysBlank\) screenDpmsSettleTimer\.restart\(\)/.test(service) &&
    !/function onScreensChanged\(\) \{[^}]*root\.displaysBlank = false/.test(service),
  'a panel coming back asks which panels are dark instead of dropping the blank state'
)

// Run the service's own DPMS bookkeeping against a stand-in for the lock root.
function extract(name) {
  const match = service.match(new RegExp(`\\n  function ${name}\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}\\n`))
  if (!match) fail(`Service.qml defines ${name}`)
  return match[0]
}
const anyDisplayBlankExpr = service.match(/readonly property bool anyDisplayBlank: (.*)\n/)[1]
const makeService = new Function('state', `with (state) {
  ${extract('anyMonitorDark')}
  ${extract('applyMonitorDpms')}
  ${extract('settleScreenDpms')}
  return {
    settle: settleScreenDpms,
    anyDisplayBlank: () => ${anyDisplayBlankExpr}
  }
}`)

function blankedLock() {
  const state = { displaysBlank: true, monitorDpms: {}, monitorDpmsKnown: false }
  return { state, service: makeService(state) }
}

const monitors = list => JSON.stringify(list.map(([name, dpmsStatus, disabled]) => ({ name, dpmsStatus, disabled: !!disabled })))

let lock = blankedLock()
assert(lock.service.anyDisplayBlank(), 'a blanked lock treats the next key as a wake key')
lock.service.settle(monitors([['eDP-1', false], ['USB-2', true]]))
assert(lock.state.displaysBlank && lock.service.anyDisplayBlank(), 'an external panel that comes back lit leaves the key that wakes the built-in one out of the password')

lock = blankedLock()
lock.service.settle(monitors([['eDP-1', true], ['USB-2', true]]))
assert(!lock.state.displaysBlank && !lock.service.anyDisplayBlank(), 'once every panel is lit again the first key is typed')

lock = blankedLock()
lock.service.settle(monitors([['eDP-1', false, true], ['USB-2', true]]))
assert(!lock.state.displaysBlank, 'a disabled panel (clamshell) does not hold the blank state')

lock = blankedLock()
lock.service.settle('')
assert(!lock.state.displaysBlank, 'an unreadable answer gives up the blank state, as before')

lock = blankedLock()
lock.state.displaysBlank = false
lock.service.settle(monitors([['eDP-1', false]]))
assert(!lock.state.displaysBlank, 'a lit lock is never made blank by a panel coming back')
JS

TMPDIR=""
QS_PID=""

cleanup() {
  if [[ -n $QS_PID ]] && kill -0 "$QS_PID" 2>/dev/null; then
    kill "$QS_PID" 2>/dev/null || true
    wait "$QS_PID" 2>/dev/null || true
  fi
  if [[ -n $TMPDIR && -d $TMPDIR ]]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

require_compositor "lock wake key test"

if ! command -v quickshell >/dev/null 2>&1; then
  pass "quickshell not installed; skipping lock wake key test"
  exit 0
fi

require_command jq

TMPDIR=$(mktemp -d)
result="$TMPDIR/result.json"
log="$TMPDIR/quickshell.log"
config_dir="$TMPDIR/lock-wake-key"
mkdir -p "$config_dir" "$TMPDIR/home"
cp "$SHELL_TEST_DIR/fixtures/lock-wake-key/shell.qml" "$config_dir/shell.qml"
ln -s "$ROOT/shell/Ui" "$config_dir/Ui"
ln -s "$ROOT/shell/Commons" "$config_dir/Commons"

OMARCHY_PATH="$ROOT" \
OMARCHY_QML_TEST_RESULT="$result" \
HOME="$TMPDIR/home" \
XDG_CONFIG_HOME="$TMPDIR/home/.config" \
XDG_CACHE_HOME="$TMPDIR/home/.cache" \
XDG_STATE_HOME="$TMPDIR/home/.local/state" \
QML2_IMPORT_PATH="$ROOT/shell${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}" \
QML_IMPORT_PATH="$ROOT/shell${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" \
PATH="$ROOT/bin:$PATH" \
  quickshell -p "$config_dir" --no-color >"$log" 2>&1 &
QS_PID=$!

for _ in {1..80}; do
  [[ -s $result ]] && break
  if ! kill -0 "$QS_PID" 2>/dev/null; then
    sed -n '1,220p' "$log" >&2
    fail "lock wake key quickshell exited before writing result"
  fi
  sleep 0.1
done

[[ -s $result ]] || {
  sed -n '1,220p' "$log" >&2
  fail "lock wake key test timed out"
}

if ! jq -e '.ok == true' "$result" >/dev/null; then
  printf 'Lock wake key result:\n' >&2
  jq . "$result" >&2
  printf 'Lock wake key log:\n' >&2
  sed -n '1,220p' "$log" >&2
  fail "the key that wakes a blank lock is not typed into the password"
fi

pass "the key that wakes a blank lock is not typed into the password"
