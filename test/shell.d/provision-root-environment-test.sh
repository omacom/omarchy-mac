#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

for entry in omarchy-provision-owner omarchy-system-factory-reset; do
  env -i PATH=/usr/bin:/bin OMARCHY_PROVISION_OWNER_SOURCE=1 OMARCHY_FACTORY_RESET_SOURCE=1 \
    bash -c '
      unset OMARCHY_PATH
      fixture_library=$2
      # Bootstrap coverage is independent of the host hardware/package install.
      omarchy-hw-apple-silicon() { return 1; }
      # Exercise the production fallback without installing development code
      # into /usr/share. Redirect only the expected core library include.
      source() {
        if [[ $1 == "/usr/share/omarchy/install/provisioning/luks-recovery.sh" ]]; then
          builtin source "$fixture_library"
        else
          builtin source "$@"
        fi
      }
      source "$1"
      [[ $OMARCHY_PATH == "/usr/share/omarchy" && $PATH == "$OMARCHY_PATH/bin:"* ]]
    ' bash "$ROOT/bin/$entry" "$ROOT/install/provisioning/luks-recovery.sh"
  pass "$entry bootstraps without a desktop environment"
done
