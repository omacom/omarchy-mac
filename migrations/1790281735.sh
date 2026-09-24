echo "Move Apple Silicon Steam launcher to omarchy-steam-fex"

[[ $(uname -m) == "aarch64" ]] || exit 0
omarchy-pkg-present steam || exit 0
omarchy-pkg-add omarchy-steam-fex
omarchy-pkg-present omarchy-steam-fex || {
  echo "Steam launcher package omarchy-steam-fex is unavailable" >&2
  exit 1
}
omarchy-launch-steam --prepare
