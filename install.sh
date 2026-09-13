#!/bin/bash

# Bootstrap the Mac installer. The reusable implementation also ships in the
# package so setup can continue using the selected release's own scripts.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/install/helpers/mac-install.sh"
main "$@"
