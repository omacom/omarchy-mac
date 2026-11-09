#!/bin/bash

# Qt 6.12 adds QtQuick.Color, which shadows an unqualified qs.Commons Color.
# The shell singleton is registered as ShellColor so palette lookups stay defined.

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

qmldir="$ROOT/shell/Commons/qmldir"
grep -qx 'singleton ShellColor 1.0 Color.qml' "$qmldir" ||
  fail "palette singleton is registered as ShellColor"
[[ -f $ROOT/shell/Commons/Color.qml ]] ||
  fail "palette singleton implementation stays in Color.qml"

leftovers=$(grep -R -n -E '(^|[^A-Za-z0-9_])Color\.' "$ROOT/shell" --include='*.qml' --include='*.js' | grep -v 'Color\.qml' || true)
[[ -z $leftovers ]] ||
  fail "unqualified Color. references remain under shell/" "$leftovers"
pass "shell palette references use ShellColor"
