echo "Draw the pointer in software on every Apple Silicon Mac"

# A hardware cursor on Apple's display controller lags behind the hand. Earlier
# setup only switched it off on Macs without a render GPU.
omarchy-hw-apple-silicon || exit 0
omarchy-setup-mac --user
