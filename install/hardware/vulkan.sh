#!/bin/bash

# Install Vulkan drivers matching detected GPU hardware
# (NVIDIA Vulkan is handled by nvidia.sh via nvidia-utils)

declare -A VULKAN_DRIVERS=(
  [Intel]=vulkan-intel
  [AMD]=vulkan-radeon
)

PACKAGES=()

# vulkan-asahi is Mesa's Honeykrisp driver, which needs the Asahi GPU driver
# underneath it. On an SoC the kernel driver does not know yet (M3 and later on
# the public kernel) it would install fine and then find no device, while
# omarchy-hw-vulkan would report Vulkan as available. Ask whether the driver is
# actually bound, and leave the package for the kernel that binds it.
if [[ $(uname -m) == "aarch64" ]] && omarchy-hw-apple-soc >/dev/null 2>&1; then
  if omarchy-hw-apple-soc --gpu; then
    PACKAGES+=(vulkan-asahi)
  else
    echo "Apple $(omarchy-hw-apple-soc) SoC without a bound Asahi GPU driver; skipping vulkan-asahi"
  fi
fi

for vendor in "${!VULKAN_DRIVERS[@]}"; do
  if lspci | grep -iE "(VGA|Display).*$vendor" > /dev/null; then
    PACKAGES+=("${VULKAN_DRIVERS[$vendor]}")
  fi
done

if (( ${#PACKAGES[@]} > 0 )); then
  omarchy-pkg-add "${PACKAGES[@]}"
fi
