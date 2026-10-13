#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')

// WlSessionLock has changed `locked` on unlock without its change signal, so a
// binding reading it back stayed true and every later lock request was a
// no-op. The plugin keeps its own record of the lock it holds instead.
assert(
  /readonly property bool locked: lockRequested \|\| sessionLockHeld \|\| sessionLock\.secure/.test(serviceQml),
  'locked derives from the lock this plugin holds, not from sessionLock.locked'
)
assert(
  !/readonly property bool locked:[^\n]*sessionLock\.locked/.test(serviceQml),
  'locked never reads sessionLock.locked back'
)
assert(
  /sessionLockHeld = true\s*\n\s*sessionLock\.locked = true/.test(serviceQml),
  'taking the session lock records it as held'
)
assert(
  /sessionLockHeld = false\s*\n\s*sessionLock\.locked = false/.test(serviceQml),
  'finishing an unlock records the lock as released before asking the compositor'
)
assert(
  /onLockStateChanged: \{[\s\S]*?root\.sessionLockHeld = locked/.test(serviceQml),
  'a lock state change the compositor does report keeps the record in sync'
)
assert(
  /held: root\.sessionLockHeld,/.test(serviceQml),
  'lock status reports the held record for diagnosis'
)
JS
