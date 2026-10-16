#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Qt 6.12 added a global `Color` helper to QtQuick which shadows a QML
# singleton of the same name: every bare `Color.<surface>` access then binds
# to Qt's color object instead of qs.Commons, leaving all theme surfaces
# undefined and rendering the bar/menu black (omacom/omarchy-mac#722).
# The theme singleton is therefore named `Theme`, and no bare `Color.`
# reference may remain under shell/.
grep -Fq 'singleton Theme 1.0 Theme.qml' "$ROOT/shell/Commons/qmldir" || fail "qmldir declares the Theme singleton"
pass "qmldir declares the Theme singleton"

if grep -rn '\bColor\.' "$ROOT/shell" --include='*.qml' --include='*.js' | grep -v 'Qt\.color' | grep -q .; then
  leftovers=$(grep -rn '\bColor\.' "$ROOT/shell" --include='*.qml' --include='*.js' | grep -v 'Qt\.color' | head -n 5)
  fail "no bare Color. references remain under shell/" "$leftovers"
fi
pass "no bare Color. references remain under shell/"

[[ -f "$ROOT/shell/Commons/Theme.qml" ]] || fail "Theme.qml exists in shell/Commons"
pass "Theme.qml exists in shell/Commons"

if ! command -v quickshell >/dev/null; then
  pass "quickshell not installed; skipping Theme runtime resolution"
  exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
ln -s "$ROOT/shell/Commons" "$TMPDIR/Commons"
cat > "$TMPDIR/shell.qml" <<'EOF'
import Quickshell
import QtQuick
import qs.Commons

ShellRoot {
  Component.onCompleted: {
    console.log("THEME-TEST bar=" + Theme.bar);
    console.log("THEME-TEST menu=" + Theme.menu);
    try { console.log("THEME-TEST bar.background=" + Theme.bar.background); }
    catch (e) { console.log("THEME-TEST bar.background ERR=" + e); }
    Qt.quit();
  }
}
EOF

output=$(QT_QPA_PLATFORM=offscreen timeout 60 quickshell -n -p "$TMPDIR" 2>&1 || true)

if [[ $output == *"THEME-TEST bar=undefined"* ]]; then
  fail "Theme.bar resolves to the singleton (not QtQuick.Color)" "$output"
fi
pass "Theme.bar resolves to the singleton (not QtQuick.Color)"

if [[ $output == *"THEME-TEST menu=undefined"* ]]; then
  fail "Theme.menu resolves to the singleton (not QtQuick.Color)" "$output"
fi
pass "Theme.menu resolves to the singleton (not QtQuick.Color)"

if [[ $output == *"THEME-TEST bar.background ERR="* || $output == *"THEME-TEST bar.background=undefined"* ]]; then
  fail "Theme.bar.background resolves to a color" "$output"
fi
pass "Theme.bar.background resolves to a color"
