echo "Populate the finalized Omarchy Mac signing keyring"

# A successor is required for clients that already marked earlier migrations
# complete. Never remove existing keys or change repository signature policy.
installed=$(pacman -Q omarchy-mac-keyring) || {
  echo "Install the reviewed Omarchy Mac keyring package first." >&2
  exit 1
}
version=${installed#* }
comparison=$(vercmp "$version" 20260914-2) || exit 1
if (( comparison < 0 )); then
  echo "Omarchy Mac keyring 20260914-2 or newer is required." >&2
  exit 1
fi

sudo pacman-key --populate omarchy-mac || {
  echo "Could not populate Omarchy Mac signing trust; this migration remains pending." >&2
  exit 1
}
omarchy_mac_signing_key=FBD6874D423C418DDB6D143EECE19CDDE306DBD2
if ! sudo pacman-key --finger "$omarchy_mac_signing_key" | tr -d '[:space:]' | grep -qF "$omarchy_mac_signing_key"; then
  echo "The required Omarchy Mac signing primary $omarchy_mac_signing_key is missing after keyring population." >&2
  exit 1
fi
