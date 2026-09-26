#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

for entry in omarchy-provision-owner; do
  env -i PATH=/usr/bin:/bin OMARCHY_PROVISION_OWNER_SOURCE=1 \
    bash -c '
      unset OMARCHY_PATH
      fixture_libraries=$2
      # Bootstrap coverage is independent of the host hardware/package install.
      omarchy-hw-apple-silicon() { return 1; }
      # Exercise the production fallback without installing development code
      # into /usr/share. Redirect only the expected core library includes.
      source() {
        if [[ $1 == /usr/share/omarchy/install/provisioning/luks-re*.sh ]]; then
          builtin source "$fixture_libraries/${1##*/}"
        else
          builtin source "$@"
        fi
      }
      source "$1"
      [[ $OMARCHY_PATH == "/usr/share/omarchy" && $PATH == "$OMARCHY_PATH/bin:"* ]]
    ' bash "$ROOT/bin/$entry" "$ROOT/install/provisioning"
  pass "$entry bootstraps without a desktop environment"
done

# Factory reset is upstream's script: it elevates and resets when run, so only
# its bootstrap lines are checked.
reset=$ROOT/bin/omarchy-system-factory-reset
grep -Fxq 'OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"' "$reset" &&
  grep -Fxq 'export PATH="$OMARCHY_PATH/bin:$PATH"' "$reset" ||
  fail "omarchy-system-factory-reset bootstraps without a desktop environment"
pass "omarchy-system-factory-reset bootstraps without a desktop environment"
