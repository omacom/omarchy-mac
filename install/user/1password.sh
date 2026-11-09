# Shared by fresh user setup, the 1Password installer and the existing-install
# migration. Provisioning marks migrations complete, and fresh Apple Silicon
# installs ship 1Password, so the desktop entry must be installed here too.
install_1password_desktop() {
  local template="$OMARCHY_PATH/default/applications/1password.desktop"
  local target="$HOME/.local/share/applications/1password.desktop"
  local known_exec='^Exec=[[:space:]]*"?(/opt/1Password/1password|/usr/local/bin/1password|/usr/bin/1password|1password|omarchy-launch-1password)"?([[:space:]]|$)'

  omarchy-cmd-present 1password || return 0

  # Replace entries that start 1Password directly, including the vendor copy
  # and its wrapper repair. Links, directories and custom commands are the
  # user's own route.
  if [[ -L $target ]] || [[ -e $target && ! -f $target ]]; then
    echo "Preserving custom 1Password desktop route: $target" >&2
    return 0
  fi
  if [[ -f $target ]] && ! grep -Eq "$known_exec" "$target"; then
    echo "Preserving custom 1Password desktop command: $target" >&2
    return 0
  fi

  mkdir -p "${target%/*}"
  install -m 644 "$template" "$target"
  update-desktop-database "${target%/*}" 2>/dev/null || true
}

install_1password_desktop
