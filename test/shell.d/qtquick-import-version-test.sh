#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

unversioned=$(find "$ROOT/shell" -type f -name '*.qml' -print0 |
  xargs -0 grep -lE '^import QtQuick$' || true)
if [[ -n $unversioned ]]; then
  fail "shell QML pins QtQuick below the Qt 6.12 Color type" "$unversioned"
fi
pass "shell QML pins QtQuick below the Qt 6.12 Color type"
