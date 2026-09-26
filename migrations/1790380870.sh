echo "Let an encrypted Mac's recovery key set a new password before the login screen"

# Owner setup arms omarchy-drive-recover where it gives the disk a recovery key,
# as every Mac setup has; a Mac set up before gets it here. Elsewhere the disk
# has none. The platform is an assignment so an undetermined one fails the
# migration.
platform=$(omarchy-hw-platform)
[[ $platform == "apple-silicon" ]] || exit 0

root_source=$(findmnt -no SOURCE /)
ancestry=$(lsblk -nsrpo FSTYPE "${root_source%%[*}")
grep -qx crypto_LUKS <<<"$ancestry" || exit 0

# Another user's run may have armed it already; then this one needs no sudo.
unit_dir=${OMARCHY_SYSTEMD_UNIT_DIR:-/etc/systemd/system}
armed=1
for unit in omarchy-drive-recover-check.service omarchy-drive-recover.service; do
  if ! cmp -s "$OMARCHY_PATH/install/provisioning/$unit" "$unit_dir/$unit" || [[ ! -L $unit_dir/multi-user.target.wants/$unit ]]; then
    armed=0
  fi
done
if (( ! armed )); then
  sudo omarchy-drive-recover --arm
fi
