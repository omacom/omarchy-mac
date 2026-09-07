#!/bin/bash

# Shared by the standalone installer and installed package update commands.
omarchy_arm_package_targets() {
  printf '%s\n' omarchy/hyprland omarchy/hyprtoolkit omarchy/hyprland-guiutils
}

omarchy_arm_package_is_selected() {
  local target
  while read -r target; do
    [[ ${target#*/} == "$1" ]] && return 0
  done < <(omarchy_arm_package_targets)
  return 1
}

omarchy_arm_package_repo() {
  printf '%s\n' '[omarchy]' 'Usage = Sync' 'SigLevel = Required DatabaseOptional' 'Server = https://pkgs.omarchy.org/edge/$arch'
}

omarchy_arm_prepare_package_sources() {
  local config="${1:-/etc/pacman.conf}" backup="${2:-backup}" updated key="40DFB630FF42BCFFB047046CF0134EE680CAC571"
  updated=$(mktemp) || return
  # Replace an existing unrestricted Omarchy section without changing the
  # user's regular repositories, mirror choices, or their ordering.
  awk '
    /^[[:space:]]*\[/ { omit = ($0 ~ /^[[:space:]]*\[omarchy\][[:space:]]*(#.*)?$/) }
    !omit { print }
  ' "$config" > "$updated" || { rm -f "$updated"; return 1; }
  omarchy_arm_package_repo >> "$updated" || { rm -f "$updated"; return 1; }
  if ! cmp -s "$config" "$updated"; then
    if [[ $backup != "preserve-backup" ]]; then
      sudo cp "$config" "$config.bak" || { rm -f "$updated"; return 1; }
    fi
    sudo install -m 644 "$updated" "$config" || { rm -f "$updated"; return 1; }
  fi
  rm -f "$updated"

  if ! sudo pacman-key --list-keys "$key" >/dev/null 2>&1; then
    sudo pacman-key --recv-keys "$key" --keyserver hkps://keys.openpgp.org || return
  fi
  sudo pacman-key --lsign-key "$key"
}
