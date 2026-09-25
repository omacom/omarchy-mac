echo "Hand the Apple Silicon keyboard's function-key mode to omarchy-mac"

omarchy-hw-apple-silicon || exit 0

# Name the hid_apple.conf line Omarchy generated here. The install leaf wrote
# fnmode=2, and each fork's keyboard migration replaced it once: with fnmode=1
# (quattro-upstream 1789132067) or fnmode=3 (mx-mac 1790305681). After either
# ran, any other line, fnmode=2 included, is the owner's choice.
state="${OMARCHY_MIGRATION_STATE:-$HOME/.local/state/omarchy/migrations}"
generated=2
[[ ! -f $state/1789132067.sh ]] || generated=1
[[ ! -f $state/1790305681.sh ]] || generated=3

sudo omarchy-mac-setup-keyboard "$generated"
