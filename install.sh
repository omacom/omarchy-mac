#!/bin/bash

# Architecture dispatcher. aarch64 has no Omarchy ISO, so it runs the Apple
# Silicon installer. x86 installs from https://omarchy.org/.

set -euo pipefail

readonly checkout="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$checkout/bin:${PATH:-}"

machine_arch=$("$checkout/bin/omarchy-hw-arch") || {
  echo "Cannot determine a supported architecture; installation has not started." >&2
  exit 1
}
case $machine_arch in
  aarch64) exec bash "$checkout/install/aarch64/install.sh" "$@" ;;
  x86_64)
    echo "On x86_64, install Omarchy from the ISO: https://omarchy.org/" >&2
    exit 1
    ;;
esac
