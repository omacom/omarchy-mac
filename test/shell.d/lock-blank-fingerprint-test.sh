#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')

// The fingerprint PAM stays armed for the whole lock waiting for a finger, so
// `authenticating` is true from lock until unlock on every machine with a
// reader enrolled. Gating the blank on it leaves the panel lit all night.
assert(
  /if \(root\.lockRequested && !root\.authenticatingPassword\) root\.runBlank\(\)/.test(serviceQml),
  'only a password check in flight stops the blank timer from blanking'
)

assert(
  !/idleBlankTimer[\s\S]*?!root\.authenticating\)/.test(serviceQml),
  'the blank timer never gates on the combined authenticating state'
)

assert(
  /onAuthenticatingPasswordChanged: \{\s*if \(!lockRequested\) return\s*if \(authenticatingPassword\) idleBlankTimer\.stop\(\)\s*else if \(authenticationVisible\) armBlankTimer\(\)/.test(serviceQml),
  'password completion re-arms blanking only after authentication is revealed'
)

assert(
  /function beginLock\(\)[\s\S]*?authenticationVisible = false\s*idleBlankTimer\.stop\(\)\s*lockRequested = true/.test(serviceQml),
  'locking keeps the concealed screensaver lit'
)

assert(
  /function runWake\(\)[\s\S]*?if \(lockRequested && authenticationVisible\) armBlankTimer\(\)/.test(serviceQml),
  'display blanking starts only after authentication is revealed'
)

assert(
  !/onAuthenticatingChanged:/.test(serviceQml),
  'the combined authenticating state no longer drives the blank timer'
)
JS
