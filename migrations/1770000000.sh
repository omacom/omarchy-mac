echo "Install Widevine CDM for DRM streaming support"

# Migration: Install Widevine CDM for DRM streaming support (Netflix, etc.)
# This ensures existing Omarchy installations get DRM support

set -euo pipefail

echo "Checking Widevine CDM installation for DRM streaming support..."

if [[ $(uname -m) != "aarch64" ]] || [[ ! -f /proc/device-tree/compatible ]] || ! grep -qi "apple" /proc/device-tree/compatible 2>/dev/null; then
  echo "Skipping Widevine migration: not an Apple Silicon aarch64 system"
  exit 0
fi

# Only install if widevine package is available (asahi-alarm repo)
if pacman -Si widevine &>/dev/null; then
  if ! pacman -Qi widevine &>/dev/null; then
    echo "Installing widevine package for Netflix/DRM streaming support..."
    omarchy-pkg-add widevine
    echo "✓ Widevine CDM installed successfully"
  else
    echo "✓ Widevine already installed"
  fi
else
  echo "ℹ Widevine package not available in configured repositories (this is expected on non-aarch64 systems)"
fi

echo "Migration complete."
