echo "Put Omarchy actions on the Apple Silicon Touch Bar"

touchbar_setup="$OMARCHY_PATH/install/hardware/apple/touchbar.sh"
[[ -f $touchbar_setup ]] || exit 0

source "$touchbar_setup"
