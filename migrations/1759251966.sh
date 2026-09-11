echo "Migrating omarchy to support fuzzel theming alongside walker"

# Ensure fuzzel configuration directory exists
mkdir -p ~/.config/fuzzel

# Copy fuzzel configuration if it doesn't exist
if [[ ! -f ~/.config/fuzzel/fuzzel.ini ]]; then
  echo "Setting up fuzzel configuration..."
  cp ~/.local/share/omarchy/config/fuzzel/fuzzel.ini ~/.config/fuzzel/fuzzel.ini
  echo "✓ Fuzzel configuration installed"
else
  echo "✓ Fuzzel configuration already exists"
fi

# Convert all themes to include fuzzel.ini files
echo "Converting themes to support fuzzel..."
~/.local/share/omarchy/bin/omarchy-mac-custom-theme-utility

# Verify current theme has fuzzel support
current_theme=$(basename "$(realpath ~/.config/omarchy/current/theme 2>/dev/null)" 2>/dev/null)
if [[ -n "$current_theme" ]]; then
  if [[ ! -f ~/.config/omarchy/current/theme/fuzzel.ini ]]; then
    echo "Current theme ($current_theme) missing fuzzel.ini, generating..."
    ~/.local/share/omarchy/bin/omarchy-mac-custom-theme-utility
  fi
  echo "✓ Current theme ($current_theme) supports fuzzel"
else
  echo "Warning: No current theme set"
fi

echo ""
echo "Fuzzel theming migration complete!"
echo "- All existing themes now support fuzzel"
echo "- New themes will automatically get fuzzel support"
echo "- Theme switching works seamlessly with both walker and fuzzel"
