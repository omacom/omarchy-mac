echo "Install the Apple Silicon Vulkan driver on installs that missed it"

# The pre-quattro hardware backfill looked for an Apple GPU in lspci, but the
# Apple Silicon GPU is a device-tree platform device and never shows up there,
# so installs that predate install/hardware/vulkan.sh never got vulkan-asahi.
omarchy-hw-apple || exit 0
omarchy-pkg-missing vulkan-asahi || exit 0
omarchy-pkg-add vulkan-asahi
