echo "Fix keyboard layout support for non-US keyboards"

# Migration: Fix keyboard layout support for non-US keyboards
# This migration updates input.conf with the correct kb_options and notifies users
# about the keyboard layout configuration option in Menu > Setup

set -euo pipefail

STATE_DIR="$HOME/.local/state/omarchy/migrations"
STATE_FILE="$STATE_DIR/1770012336.sh"

INPUT_CONF="$HOME/.config/hypr/input.conf"
INPUT_CONF_BACKUP="$HOME/.config/hypr/input.conf.backup-$(date +%Y%m%d-%H%M%S)"

echo "Applying keyboard layout fix for non-US keyboards..."

# Check if input.conf exists
if [[ ! -f "$INPUT_CONF" ]]; then
    echo "No input.conf found, skipping migration"
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    exit 0
fi

# Check if already has the correct option
if grep -q "grp:shifts_toggle" "$INPUT_CONF" 2>/dev/null; then
    echo "Keyboard layout fix already applied"
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    exit 0
fi

# Backup the current config
if grep -q "grp:alts_toggle" "$INPUT_CONF" 2>/dev/null; then
    echo "Backing up input.conf..."
    cp "$INPUT_CONF" "$INPUT_CONF_BACKUP"
    
    # Replace alts_toggle with shifts_toggle
    sed -i 's/grp:alts_toggle/grp:shifts_toggle/g' "$INPUT_CONF"
    echo "✓ Updated kb_options from grp:alts_toggle to grp:shifts_toggle"
    echo "  (Backup saved to: $INPUT_CONF_BACKUP)"
fi

# Check current keyboard layout
CURRENT_LAYOUT=$(localectl status | grep "X11 Layout" | awk '{print $3}' 2>/dev/null || echo "(unset)")

echo ""
echo "✓ Keyboard layout fix applied!"
echo ""
echo "Current keyboard layout: $CURRENT_LAYOUT"
echo ""

# Notify user about keyboard layout configuration
if [[ "$CURRENT_LAYOUT" == "(unset)" ]] || [[ "$CURRENT_LAYOUT" == "us" ]]; then
    echo "ℹ  Your keyboard layout is currently set to US English."
    echo ""
    echo "If you use a non-US keyboard layout:"
    echo "  1. Open Menu (Super+M) > Setup > Keyboard Layout"
    echo "  2. Or run: omarchy-setup-keyboard"
    echo ""
    echo "This will configure your keyboard layout for:"
    echo "  • System-wide key mapping"
    echo "  • Console and X11 environments"
    echo "  • Proper modifier key behavior"
    echo ""
fi

echo "Note: The kb_options change fixes keyboard layout switching to use"
echo "      Shift+Shift instead of Alt+Alt, which works better for non-US keyboards."

# Mark migration as complete
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

echo ""
echo "Migration complete."
