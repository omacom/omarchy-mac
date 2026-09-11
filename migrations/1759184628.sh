echo "Migrating from walker to omarchy-mac-menu (fuzzel-based) for better aarch64 compatibility"

# Check if fuzzel is installed
if ! command -v fuzzel >/dev/null 2>&1; then
  echo "Installing fuzzel..."
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm fuzzel
  elif command -v yay >/dev/null 2>&1; then
    yay -S --noconfirm fuzzel
  else
    echo "Please install fuzzel manually: sudo pacman -S fuzzel"
    exit 1
  fi
fi

mkdir -p ~/.config/fuzzel
cp -r ~/.local/share/omarchy/config/fuzzel/* ~/.config/fuzzel/

# Remove walker if it's installed (optional)
if command -v walker >/dev/null 2>&1; then
  echo "Walker is still installed. You can remove it with: sudo pacman -R walker"
fi

echo "Migration complete! omarchy-mac-menu (fuzzel) is now active."
echo "The main launcher (SUPER+SPACE) now uses fuzzel for better performance on aarch64."
