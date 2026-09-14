echo "Trust packages signed by Omarchy Mac"

readonly omarchy_mac_signing_key='F3C5AE3FCFFC738C301E30A8F0C548C0D27279F7'

# The package is a dependency of omarchy, but keep this self-repairing for a
# partial/manual upgrade. Do not weaken the repository policy to fetch it.
if omarchy-pkg-missing omarchy-mac-keyring; then
  omarchy-pkg-add omarchy-mac-keyring
fi

sudo pacman-key --populate omarchy-mac
sudo pacman-key --finger "$omarchy_mac_signing_key" | tr -d '[:space:]' | grep -qF "$omarchy_mac_signing_key"

# Policy remains unchanged for this one disclosed bootstrap transaction. The
# next, signed RC carries a successor migration that requires both package and
# database signatures after this key is already durable.
