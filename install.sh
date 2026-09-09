#!/bin/bash

# Architecture dispatcher. aarch64 has no Omarchy ISO, so it runs the Apple
# Silicon installer. x86 installs from https://omarchy.org/.

set -euo pipefail

readonly checkout="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$checkout/bin:${PATH:-}"

if "$checkout/bin/omarchy-hw-aarch64"; then
  exec bash "$checkout/install/aarch64/install.sh" "$@"
fi

echo "On x86_64, install Omarchy from the ISO: https://omarchy.org/" >&2
echo "aarch64 uses install/aarch64/install.sh." >&2
exit 1
