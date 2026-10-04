echo "Move this Mac onto Omarchy's official packages on the next update"

# omarchy-mac's quattro line ends here: Omarchy's own packages now carry the
# Mac (omarchy-mac and omarchy-mac-boot, from omacom/omarchy-mac-pkgs). This
# marks the Mac, machine-wide; the next omarchy update moves it with
# omarchy-mac-migrate before any fork step, and stops there for the reboot.
# Until the Mac's channel has a Mac release, those updates leave it as it is and
# update it as before. Once a run marked it, other accounts skip this.
marker="${OMARCHY_MAC_MOVE_MARKER:-/var/lib/omarchy/migrations/1791080196}"
[[ ! -e $marker ]] || exit 0
omarchy-hw-apple || exit 0

sudo install -Dm644 /dev/null "$marker"
echo "The next omarchy update moves this Mac onto Omarchy's official packages, once its channel has a Mac release."
