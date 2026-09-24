#!/bin/bash

# Install Vulkan drivers matching detected GPU hardware
# (NVIDIA Vulkan is handled by nvidia.sh via nvidia-utils)

declare -A VULKAN_DRIVERS=(
  [Intel]=vulkan-intel
  [AMD]=vulkan-radeon
)

PACKAGES=()

if [[ $(uname -m) == "aarch64" ]] && [[ -f /proc/device-tree/compatible ]] && grep -qai "apple" /proc/device-tree/compatible 2>/dev/null; then
  PACKAGES+=(vulkan-asahi)
fi

for vendor in "${!VULKAN_DRIVERS[@]}"; do
  if lspci | grep -iE "(VGA|Display).*$vendor" > /dev/null; then
    PACKAGES+=("${VULKAN_DRIVERS[$vendor]}")
  fi
done

if (( ${#PACKAGES[@]} > 0 )); then
  omarchy-pkg-add "${PACKAGES[@]}"
fi
