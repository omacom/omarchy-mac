#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

for entry in omarchy-provision-owner omarchy-system-factory-reset; do
  env -i PATH=/usr/bin:/bin OMARCHY_PROVISION_OWNER_SOURCE=1 OMARCHY_FACTORY_RESET_SOURCE=1 \
    bash -c 'unset OMARCHY_PATH; source "$1"; [[ $OMARCHY_PATH == "/usr/share/omarchy" && $PATH == "$OMARCHY_PATH/bin:"* ]]' bash "$ROOT/bin/$entry"
  pass "$entry bootstraps without a desktop environment"
done
