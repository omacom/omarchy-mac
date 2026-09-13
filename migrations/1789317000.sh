echo "Require trusted Omarchy Mac package and database signatures"

readonly omarchy_mac_signing_key='F3C5AE3FCFFC738C301E30A8F0C548C0D27279F7'
readonly strict_omarchy_mac_policy='PackageRequired DatabaseRequired TrustedOnly'

# The unsigned rc4 bootstrap must already have delivered this trust. Do not
# weaken policy or retrieve a key from the network to repair a skipped step.
if omarchy-pkg-missing omarchy-mac-keyring; then
  echo "Omarchy Mac signing trust is missing; install the reviewed rc4 bootstrap before this RC." >&2
  return 1
fi
sudo pacman-key --populate omarchy-mac
sudo pacman-key --finger "$omarchy_mac_signing_key" | tr -d '[:space:]' | grep -qF "$omarchy_mac_signing_key"

source "$OMARCHY_PATH/install/helpers/arm-channel.sh"
omarchy_arm_signature_policy_apply /etc/pacman.conf "$strict_omarchy_mac_policy"
