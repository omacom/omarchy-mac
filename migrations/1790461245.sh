echo "Move this Mac onto Omarchy's official packages with the released omarchy-mac-boot"

# Only this runtime carries it; official Omarchy reaches a Mac through
# 1790347292 and its installed omarchy-mac-boot. A tester's Mac may have no
# omarchy-mac-boot or an unofficial one, and may have run 1790347292 before
# any target existed, so this runs the engine from a verified download of the
# official package. Until that package ships its target, and while preflight
# refuses, it exits 75 and stays pending without holding up the update. The
# work is machine-wide: once it ran, the marker spares every other account.
marker="${OMARCHY_MAC_ACTIVATION_MARKER:-/var/lib/omarchy/migrations/1790461245}"
[[ ! -e $marker ]] || exit 0

platform=$(omarchy-hw-platform)
[[ $platform == "apple-silicon" ]] || exit 0

sudo omarchy-mac-migrate-bootstrap
sudo install -Dm644 /dev/null "$marker"
