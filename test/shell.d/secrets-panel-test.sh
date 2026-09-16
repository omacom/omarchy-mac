#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const panelSource = fs.readFileSync(root + '/shell/plugins/secrets/Panel.qml', 'utf8')
const manifest = JSON.parse(fs.readFileSync(root + '/shell/plugins/secrets/manifest.json', 'utf8'))
const menu = fs.readFileSync(root + '/default/omarchy/omarchy-menu.jsonc', 'utf8')

assert(manifest.id === 'omarchy.secrets', 'plugin id is omarchy.secrets')
assert(manifest.entryPoints.panel === 'Panel.qml', 'panel entry point resolves')
assert(menu.includes('"setup.security.secrets"'), 'menu defines the secrets entry')
assert(menu.includes('summon omarchy.secrets'), 'menu action summons the plugin id the manifest declares')

// Backend: every secret operation routes through the native commands; the
// panel never touches Secret Service or wl-copy directly beyond the copy pipe.
assert(/command: \["omarchy-secrets-list"\]/.test(panelSource), 'list uses omarchy-secrets-list')
assert(/v=\$\(omarchy-secrets-get \\\"\$1\\\" \\\"\$2\\\"\) && printf %s \\\"\$v\\\" \| wl-copy --sensitive/.test(panelSource),
  'copy pipes get into wl-copy --sensitive only on get success')
assert(/setProc\.command = \["omarchy-secrets-set", service, account\]/.test(panelSource), 'add uses omarchy-secrets-set')
assert(/exec omarchy-secrets-delete \\\"\$1\\\" \\\"\$2\\\"/.test(panelSource), 'delete acts on service/account identity, never a row index')
assert(/omarchy-secrets-clipclear \\\"\$1\\\" \\\"\$2\\\"[\s\S]*exec omarchy-secrets-delete/.test(panelSource),
  'delete purges the clipboard first while the keyring copy still exists')

// The secret value must never land in a QML property: it is piped on copy and
// written to the child's stdin from the started handler on add. stdinEnabled
// is re-armed per run so a second add in one summon still delivers EOF.
assert(/stdinEnabled: true[\s\S]*onStarted: \{\s*write\(secretField\.text\)/.test(panelSource), 'add writes the secret to stdin after started')
assert(/setProc\.stdinEnabled = true\s*\n\s*setProc\.running = true/.test(panelSource), 'stdin re-arms before each add')

// Clipboard hygiene: --sensitive skips clipboard history; the 30s clear is a
// detached systemd timer so it survives the copy-then-dismiss flow, and
// clipclear re-verifies the clipboard still holds the copied secret.
assert(/wl-copy --sensitive/.test(panelSource), 'copy marks the clipboard sensitive')
assert(/systemd-run", "--user", "--quiet", "--on-active=30", "--",[\s\S]*"omarchy-secrets-clipclear"/.test(panelSource),
  'clipboard clear is scheduled detached, surviving panel dismiss')
assert(/Util\.execArgv\(\["systemd-run"[\s\S]*root\.copyingService, root\.copyingAccount/.test(panelSource),
  'timed clear carries the identity captured at copy time')
assert(!/clipProc|clipTimer|copiedService/.test(panelSource), 'no in-panel clear machinery left to die on dismiss')

// Identity capture: the async exit cannot read a moved selection.
assert(/function copySelected\(\) \{[\s\S]*root\.copyingService = String\(it\.service\)[\s\S]*copyProc\.command/.test(panelSource),
  'copy captures identity before the async exit')

// Keyboard contract.
assert(/onMoveRequested/.test(panelSource), 'arrows/jk move the selection')
// PanelKeyCatcher fires activateRequested for Return/Enter/Space; a separate
// returnRequested binding would run the copy pipeline twice per Enter.
assert(/onActivateRequested: \{ if \(!root\.vaultOpen\) root\.copySelected\(\) \}/.test(panelSource), 'enter/space copies')
assert(!/onReturnRequested/.test(panelSource), 'no duplicate returnRequested copy binding')
assert(/onDeleteRequested: \{ if \(!root\.vaultOpen\) root\.requestDeleteSelected\(\) \}/.test(panelSource), 'x requests deletion')
assert(/t === "\/"/.test(panelSource), '/ focuses the filter')
assert(/t === "v"\) root\.cycleVault\(\)/.test(panelSource), 'v cycles vaults')
assert(/t === "s"\) root\.cycleSort\(\)/.test(panelSource), 's cycles sort')
assert(/t === "r"\) root\.refresh\(\)/.test(panelSource), 'r refreshes')
assert(/if \(root\.vaultOpen\) \{ root\.vaultOpen = false; return \}/.test(panelSource), 'escape closes the vault picker before the panel')
assert(/onMoveRequested: function\(dx, dy\) \{[\s\S]*if \(root\.vaultOpen\) return/.test(panelSource),
  'keys cannot act on the hidden list while the vault picker is open')

// Organization: vault dropdown with per-service counts, name/recent sort, and
// provenance badges. The unfiltered state is a null sentinel so a service
// literally named "*" can never collide with it.
assert(/readonly property var allVaults: null/.test(panelSource), 'all-vaults sentinel cannot collide with a service name')
assert(/property var vault: allVaults/.test(panelSource), 'vaults default to all')
assert(/sortMode === "recent"[\s\S]*b\.modified \|\| 0\) - \(a\.modified/.test(panelSource), 'recent sort uses modified timestamps')
assert(/modelData\.app !== "omarchy"/.test(panelSource), 'external badge reads the app attribute')
assert(/text: isActionable \? "ext" : "other app"/.test(panelSource), 'rows badge foreign credentials')

// Safety: delete goes through the confirm dialog and discloses foreign
// ownership; close() wipes fields and pending identities; coalesced
// copy/delete/refresh guards exist; stderr surfaces only on nonzero exit.
assert(/ConfirmDialog[\s\S]*confirmText: "Delete"/.test(panelSource), 'deletion confirms first')
assert(/Managed by " \+ it\.app/.test(panelSource), 'delete discloses foreign ownership')
assert(/function close\(\)[\s\S]*secretField\.text = ""/.test(panelSource), 'close() wipes secret-bearing fields')
assert(/if \(copyProc\.running\) \{ root\.pendingCopy = true; return \}/.test(panelSource), 'copy coalesces while one is in flight')
assert(/if \(listProc\.running\) \{ root\.refreshPending = true; return \}/.test(panelSource), 'refresh queues behind a running list')
assert(/if \(!it \|\| !actionable\(it\) \|\| root\.deleting\) return/.test(panelSource), 'delete is guarded')
assert(/onClicked: \{ root\.selectedIndex = index; root\.copySelected\(\) \}/.test(panelSource),
  'click copies the clicked row, not the keyboard selection')
assert(/id: stallTimer[\s\S]*"Waiting on the keyring/.test(panelSource),
  'a stalled keyring call surfaces a notice instead of hanging silently')
assert(/property string lastStderr/.test(panelSource) && /lastStderr !== "" \?/.test(panelSource),
  'stderr surfaces only on nonzero exit, not on success diagnostics')
assert(/if \(!root\.opened\) return/.test(panelSource), 'in-flight process exits cannot repopulate a closed panel')
JS
