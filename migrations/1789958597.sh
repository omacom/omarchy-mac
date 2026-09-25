echo "Install vulkan-asahi after the Mesa 26.2 ICD split on Apple Silicon"

omarchy-hw-apple || exit 0
omarchy-pkg-add vulkan-asahi
