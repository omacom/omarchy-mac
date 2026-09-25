// Shared checks for the independently run x86_64 and Apple Silicon menu tests.
const fs = require('fs')
const os = require('os')
const { spawnSync } = require('child_process')
const menu = requireFromRoot('shell/plugins/menu/MenuModel.js')
const items = menu.parseMenuJsonc(fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8'))

// Recipes whose package name is a variable resolved at runtime carry their
// base package here; the menu action itself is what would drift.
const overrides = {
  'install.ai.ollama': ['ollama'],
  'install.terminal.alacritty': ['alacritty'],
  'install.terminal.foot': ['foot'],
  'install.terminal.ghostty': ['ghostty'],
  'install.terminal.kitty': ['kitty']
}

// Rows that build from the AUR instead of the sync database.
const aurOnly = new Set(items.filter(item => (item.when || '').startsWith('[[ $(uname -m)')).map(item => item.id))

// Let Bash resolve architecture branches, arrays and conditional guards.
// These recipes each have one package transaction. Stop at that request,
// before any configuration writes, driver changes or application launch.
// An empty PATH makes unmocked commands fail instead of reaching the host.
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-menu-transactions-'))
process.on('exit', () => fs.rmSync(sandbox, { recursive: true, force: true }))
const dynamicRecipes = new Set(['omarchy-install-preinstalls', 'omarchy-install-gaming-steam', 'omarchy-install-gaming-xbox-controllers'])
function probe(mode, value, platform, missing = '') {
  const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-euc', String.raw`
    uname() { [[ $1 == "-m" ]] && printf '%s\n' "$TEST_ARCH"; }
    omarchy-hw-apple-silicon() { [[ $TEST_APPLE == "1" ]]; }
    omarchy-pkg-kernel-headers() { if [[ $TEST_APPLE == "1" ]]; then echo linux-aurora-headers; else echo linux-headers; fi; }
    gum() { [[ $1 == "confirm" ]]; }
    omarchy-refresh-applications() { :; }
    omarchy-pkg-add() { printf '%s\n' "$@" >&3; exit 0; }
    omarchy-pkg-available() {
      local package
      printf '%s\n' "$@" >&3
      for package in "$@"; do
        if [[ $package == "$TEST_MISSING" ]]; then return 1; fi
      done
    }
    command_not_found_handle() { printf 'Unexpected command: %s\n' "$*" >&2; return 127; }
    if [[ $1 == "recipe" ]]; then source "$2"; else eval "$2"; fi
  `, 'menu-transaction-test', mode, value], {
    env: { PATH: sandbox, HOME: sandbox, OMARCHY_PATH: root, LC_ALL: 'C', TEST_ARCH: platform.arch, TEST_APPLE: platform.apple, TEST_MISSING: missing },
    stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
    encoding: 'utf8',
    timeout: 5000
  })
  if (result.error || result.signal || result.stderr || ![0, 1].includes(result.status)) {
    fail(`isolated ${mode} probe succeeds on ${platform.arch}`, result.error?.message || result.stderr || String(result.status))
  }
  return { status: result.status, packages: [...new Set((result.output[3] || '').trim().split('\n').filter(Boolean))] }
}

// Split a menu action the way the shell would, honouring single quotes.
function tokenize(text) {
  const tokens = []
  let current = ''
  let quoted = false
  let seen = false
  for (const char of text) {
    if (char === "'") { quoted = !quoted; seen = true; continue }
    if (!quoted && /\s/.test(char)) {
      if (seen) tokens.push(current)
      current = ''
      seen = false
      continue
    }
    current += char
    seen = true
  }
  if (seen) tokens.push(current)
  return tokens
}

// Package names that follow omarchy-pkg-add / omarchy-pkg-aur-add in a run
// of script lines, with continuations joined and comments dropped. A shell
// metacharacter ends the command; a variable is a name the recipe resolves
// itself, so it is left to the overrides.
function packageNamesIn(lines) {
  const joined = lines.join('\n').replace(/\\\n/g, ' ')
  const names = []
  for (let line of joined.split('\n')) {
    line = line.replace(/#.*/, '')
    const pattern = /omarchy-pkg-(?:aur-)?add\s+([^;&|<>]*)/g
    let match
    while ((match = pattern.exec(line))) {
      for (const token of match[1].trim().split(/\s+/)) {
        const name = token.replace(/^["']|["']$/g, '')
        if (!name || name.includes('$')) continue
        if (!names.includes(name)) names.push(name)
      }
    }
  }
  return names
}

// A recipe taking a selector installs from one case arm; the arm may hand
// off to a function defined in the same script, which is followed once.
function functionBodies(lines) {
  const bodies = {}
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(/^([a-z_]+)\(\)\s*\{\s*$/)
    if (!match) continue
    const body = []
    for (let j = i + 1; j < lines.length && lines[j] !== '}'; j++) body.push(lines[j])
    bodies[match[1]] = body
  }
  return bodies
}

function caseArm(lines, selector) {
  const start = lines.findIndex(line => new RegExp(`^\\s*'?${selector}'?\\)`).test(line))
  if (start < 0) return null
  const arm = []
  for (let i = start; i < lines.length; i++) {
    arm.push(lines[i].replace(/;;.*/, ''))
    if (/;;/.test(lines[i])) break
  }
  return arm
}

function scriptTransaction(command, selector, platform) {
  const file = path.join(root, 'bin', command)
  if (!fs.existsSync(file)) return null
  if (dynamicRecipes.has(command)) {
    const result = probe('recipe', file, platform)
    if (result.status !== 0 || !result.packages.length) fail(`${command} reaches its package request on ${platform.arch}`)
    return result.packages
  }
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  if (!selector) return packageNamesIn(lines)
  const arm = caseArm(lines, selector)
  if (!arm) return null
  const bodies = functionBodies(lines)
  const expanded = []
  for (const line of arm) {
    const call = line.trim().match(/^([a-z_]+)$/)
    if (call && bodies[call[1]]) expanded.push(...bodies[call[1]])
    else expanded.push(line)
  }
  return packageNamesIn(expanded)
}

function deriveTransaction(item, platform) {
  if (overrides[item.id]) return overrides[item.id]
  const action = item.action || ''

  // The packages sit in the action itself, right after the display name.
  const direct = action.match(/omarchy-install-(?:and-launch|app|font) (.*)$/)
  if (direct) {
    const tokens = tokenize(direct[1])
    return tokens.length > 1 ? tokens[1].split(/\s+/) : null
  }

  // The action runs a recipe, possibly through the floating terminal, which
  // takes the whole command as one quoted argument.
  const probe = action.replace(/^omarchy-launch-floating-terminal-with-presentation /, '')
  let tokens = tokenize(probe)
  if (tokens.length === 1) tokens = tokens[0].split(/\s+/)
  const command = tokens[0] || ''
  if (!/^omarchy-(install-|voxtype-install$)/.test(command)) return null
  const selector = /^omarchy-install-(browser|terminal|dev-env)$/.test(command) ? tokens[1] : ''
  return scriptTransaction(command, selector, platform)
}

const platform = { arch: process.env.OMARCHY_TEST_ARCH, apple: process.env.OMARCHY_TEST_ARCH === 'aarch64' ? '1' : '0' }
const derived = new Map()
for (const item of items) {
  if (!item.id.startsWith('install.') || !item.action || aurOnly.has(item.id)) continue
  const packages = deriveTransaction(item, platform)
  if (packages && packages.length) derived.set(item.id, packages)
}
assert(derived.size > 0, 'optional transactions can be derived from the install recipes')

const committed = new Map(items.filter(item => (item.when || '').startsWith('omarchy-pkg-available ')).map(item => {
  const result = probe('guard', item.when, platform)
  if (result.status !== 0) fail(`${item.id} is available when its packages exist on ${platform.arch}`)
  return [item.id, result.packages]
}))

// Compare as sets: the menu owns row order and comments, the recipes
// own the contents.
const render = map => [...map.keys()].sort().map(id => `${id}|${[...map.get(id)].sort().join(' ')}`).join('\n')
const wanted = render(derived)
const actual = render(committed)
assert(
  wanted === actual,
  `optional menu targets match the install recipes on ${platform.arch}`,
  `derived from the recipes:\n${wanted}\n\ndeclared in menu conditions:\n${actual}`
)

// Every derived sync row and declared AUR row is guarded: a guard without a
// transaction reports unavailable for every architecture.
const guarded = items.filter(item => /^(omarchy-pkg-available |\[\[ \$\(uname -m\))/.test(item.when || '')).map(item => item.id).sort()
assertDeepEqual(guarded, [...derived.keys(), ...aurOnly].sort(), 'optional install guards cover exactly the rows with a transaction')

// Matching a list is insufficient: || and ! can accidentally make a required
// dependency optional. Each requested package must independently hide the row
// when unavailable, while an unrelated missing package must not hide it.
for (const [id, packages] of derived) {
  const condition = items.find(item => item.id === id).when
  for (const missing of packages) {
    if (probe('guard', condition, platform, missing).status !== 1) {
      fail(`${id} requires ${missing} on ${platform.arch}`)
    }
  }
  if (probe('guard', condition, platform, 'unrelated-test-package').status !== 0) {
    fail(`${id} ignores unrelated unavailable packages on ${platform.arch}`)
  }
}
pass(`optional menu guards enforce every required package on ${platform.arch}`)
