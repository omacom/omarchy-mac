#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
exec bash "$ROOT/packages/omarchy-mac/boot/test/mac-encrypt-boot-update-test.sh"
