#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const service = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')

function extract(name) {
  const match = service.match(new RegExp(`\\n  function ${name}\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}\\n`))
  if (!match) fail(`Service.qml defines ${name}`)
  return match[0]
}

function runUp(name) {
  const match = service.match(new RegExp(`readonly property int ${name}: (\\d+)`))
  if (!match) fail(`Service.qml defines ${name}`)
  return Number(match[1])
}

const blankRunUp = runUp('blankRunUp')
const wakeRunUp = runUp('wakeRunUp')
assert(blankRunUp === 5000, 'an untouched lock still goes dark after five seconds')
assert(wakeRunUp >= 30000, 'a woken lock stays lit for at least thirty seconds')

// Run the service's own timer bookkeeping against a stand-in for the lock root
// and a clock the test moves by hand.
function makeLock() {
  const clock = { now: 1000000 }
  const timer = {
    running: false,
    interval: blankRunUp,
    armedAt: 0,
    restart() { this.running = true },
    // When the countdown would fire, or 0 if it is not running.
    dueAt() { return this.running ? this.armedAt + this.interval : 0 }
  }
  const state = {
    Date: { now: () => clock.now },
    displaysBlank: false,
    monitorDpmsKnown: false,
    lockRequested: true,
    blankRunUp,
    wakeRunUp,
    wakeProcess: { running: false },
    idleBlankTimer: timer
  }
  state.root = state
  const fns = new Function('state', `with (state) {
    ${extract('armBlankTimer')}
    ${extract('runWake')}
    return { armBlankTimer, runWake }
  }`)(state)
  return {
    state, timer, clock, ...fns,
    after(ms) { clock.now += ms },
    blank() { timer.running = false; state.displaysBlank = true }
  }
}

let lock = makeLock()
lock.armBlankTimer()
assert(lock.timer.dueAt() === lock.clock.now + blankRunUp, 'taking the lock arms the short run-up')

lock.blank()
lock.after(60000)
lock.runWake()
assert(lock.timer.dueAt() === lock.clock.now + wakeRunUp, 'the key that wakes a blank panel keeps it lit for the wake run-up')
const wokeAt = lock.clock.now

lock.after(10000)
lock.runWake()
assert(lock.timer.dueAt() === wokeAt + wakeRunUp, 'input soon after a wake does not cut the wake run-up short')

lock.after(wakeRunUp - 10000 - 2000)
lock.runWake()
assert(lock.timer.dueAt() === lock.clock.now + blankRunUp, 'input near the end of the wake run-up re-arms the normal run-up')

lock = makeLock()
lock.armBlankTimer()
lock.runWake()
assert(lock.timer.dueAt() === lock.clock.now + blankRunUp, 'input at a lit lock keeps the normal run-up')

// Suspend froze the countdown: it still looks armed, but its wall-clock time has passed.
lock = makeLock()
lock.armBlankTimer()
lock.after(3600000)
lock.runWake(wakeRunUp)
assert(lock.timer.dueAt() === lock.clock.now + wakeRunUp, 'a resume re-arms the wake run-up over a countdown frozen by suspend')

lock = makeLock()
lock.state.lockRequested = false
lock.runWake()
assert(!lock.timer.running, 'waking after unlock does not arm a blank')

assert(
  /id: resumeWatchTimer[\s\S]*?onRunningChanged: lastTick = running \? Date\.now\(\) : 0/.test(service),
  'a suspend within a second of locking is still seen as a resume'
)

assert(
  /id: resumeWatchTimer[\s\S]*?if \(resumed\) \{[\s\S]*?root\.runWake\(root\.wakeRunUp\)/.test(service),
  'a resume wakes the lock with the wake run-up'
)

assert(
  /id: idleBlankTimer[\s\S]*?if \(Date\.now\(\) - armedAt > interval \+ 2000\) \{\s*root\.armBlankTimer\(root\.wakeRunUp\)/.test(service),
  'a blank countdown frozen by suspend takes the wake run-up instead of blanking'
)
JS
