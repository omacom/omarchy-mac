echo "Trust packages signed by Omarchy Mac"

readonly omarchy_mac_signing_key='FBD6874D423C418DDB6D143EECE19CDDE306DBD2'

# The package is a dependency of omarchy, but keep this self-repairing for a
# partial/manual upgrade. Do not weaken the repository policy to fetch it.
if omarchy-pkg-missing omarchy-mac-keyring; then
  omarchy-pkg-add omarchy-mac-keyring
fi

# The helper may skip an unavailable package, and an installed older package
# does not satisfy the bootstrap. Check before explicit trust population or
# completing this marker so a checkout ahead of publication fails clearly.
# If the helper installs a package, that package's own scriptlets still run.
installed_keyring=$(pacman -Q omarchy-mac-keyring) || {
  echo "Omarchy Mac keyring 20260914-2 or newer is required; install the reviewed RC4 keyring package before retrying this migration." >&2
  exit 1
}
installed_version=${installed_keyring#* }
version_comparison=$(vercmp "$installed_version" 20260914-2) || exit 1
if (( version_comparison < 0 )); then
  echo "Omarchy Mac keyring 20260914-2 or newer is required (installed: $installed_version); complete the reviewed RC4 package upgrade before retrying this migration." >&2
  exit 1
fi

sudo pacman-key --populate omarchy-mac || {
  echo "Could not populate Omarchy Mac signing trust; this migration remains pending." >&2
  exit 1
}
if ! sudo pacman-key --finger "$omarchy_mac_signing_key" | tr -d '[:space:]' | grep -qF "$omarchy_mac_signing_key"; then
  echo "The required Omarchy Mac signing primary $omarchy_mac_signing_key is missing after keyring population." >&2
  exit 1
fi

# Policy remains unchanged for this one disclosed bootstrap transaction. The
# next, signed RC carries a successor migration that requires both package and
# database signatures after this key is already durable.
