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

sudo omarchy-drive-recover --arm
