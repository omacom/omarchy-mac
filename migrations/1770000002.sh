echo "Show 1Password install instructions on Apple Silicon systems"

# The AUR package is broken for aarch64, so users can opt into the official installer script.

set -euo pipefail

# Only mention this on Apple Silicon/aarch64 systems.
if [[ $(uname -m) != "aarch64" ]] || [[ ! -f /proc/device-tree/compatible ]] || ! grep -qi "apple" /proc/device-tree/compatible 2>/dev/null; then
  echo "Skipping 1Password instructions: not an Apple Silicon aarch64 system"
  exit 0
fi

# Check if already installed
if command -v 1password >/dev/null 2>&1; then
  INSTALLED_VERSION=$(1password --version 2>/dev/null || echo "unknown")
  echo "1Password already installed (version: ${INSTALLED_VERSION})"
  exit 0
fi

echo "1Password is optional. To install the aarch64 build, run: omarchy-install-1password"
