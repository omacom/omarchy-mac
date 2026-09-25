echo "Install the packaged Steam FEX launcher on existing Apple Silicon Steam installs"

omarchy-hw-apple-silicon || exit 0
omarchy-pkg-present steam || [[ -d $HOME/.local/share/Steam ]] || exit 0
omarchy-pkg-add omarchy-steam-fex
omarchy-cmd-present omarchy-launch-steam || exit 0
omarchy-launch-steam --prepare
