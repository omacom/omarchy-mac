echo "Work around Steam Waiting for network on Apple Silicon"

[[ $(uname -m) == aarch64 ]] || exit 0
omarchy-pkg-present steam || exit 0
omarchy-pkg-present omarchy-steam-fex || exit 0
omarchy-launch-steam --prepare
