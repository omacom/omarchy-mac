echo "Replace fuzzel terminal variable with xdg-terminal-exec"

# migrations/1769999999_replace_fuzzel_terminal_var_with_xdg_terminal_exec.sh
set -euo pipefail

TS=$(date +%s)
BACKUP_SUFFIX=".bak-$TS"
TARGETS=(
  "$HOME/.config/fuzzel/fuzzel.ini"
  "$HOME/.config/omarchy/themes"
  "$HOME/.local/share/omarchy/config/fuzzel/fuzzel.ini"
  "$HOME/.local/share/omarchy/config/fuzzel/themes"
)

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "$f$BACKUP_SUFFIX"
  fi
}

process_file() {
  local f="$1"
  # Only operate on files that exist
  [ -f "$f" ] || return

  # Only replace if the terminal line is exactly one of the legacy values
  if grep -qE '^[[:space:]]*terminal=(\\\$TERMINAL|\$TERMINAL|\\\$TERMINAL -e|\$TERMINAL -e|foot)[[:space:]]*$' "$f"; then
    backup_file "$f"
    # Use sed to handle escaped $ and plain $ cases
    sed -E -i \
      -e 's/^[[:space:]]*terminal=(\\\$TERMINAL|\$TERMINAL)([[:space:]]*-e)?[[:space:]]*$/terminal=xdg-terminal-exec/' \
      -e 's/^[[:space:]]*terminal=foot[[:space:]]*$/terminal=xdg-terminal-exec/' \
      "$f"
    echo "Updated: $f"
  fi
}

for p in "${TARGETS[@]}"; do
  if [ -d "$p" ]; then
    for fn in "$p"/*.ini; do
      [ -f "$fn" ] || continue
      process_file "$fn"
    done
  else
    process_file "$p"
  fi
done

# mark migration applied (touch state file)
mkdir -p "$HOME/.local/state/omarchy/migrations"
touch "$HOME/.local/state/omarchy/migrations/1769999999_replace_fuzzel_terminal_var_with_xdg_terminal_exec.sh"
echo "Migration complete."
