#!/bin/bash

# Shared by the standalone installer and installed package update commands.
#
# Edge can stop publishing one of these for aarch64, and asking for it by
# repository then fails the whole transaction with "target not found". Select
# only what the synced edge database carries; pacman resolves the rest from the
# regular repositories, where its dependency checks still guard the Aquamarine
# SONAME. With no readable edge database yet, select all of them as before.
omarchy_arm_package_targets() {
  local package edge
  if ! edge=$(pacman --config "${OMARCHY_PACMAN_CONFIG:-/etc/pacman.conf}" -Sl omarchy 2>/dev/null) || [[ -z $edge ]]; then
    edge=$(printf 'omarchy %s\n' hyprland hyprtoolkit hyprland-guiutils)
  fi
  for package in hyprland hyprtoolkit hyprland-guiutils; do
    if awk -v name="$package" '$2 == name { found = 1 } END { exit !found }' <<< "$edge"; then
      printf 'omarchy/%s\n' "$package"
    fi
  done
}

# --needed drops unchanged explicit targets before sysupgrade considers the
# regular repositories. Exclude those names from that implicit upgrade so a
# newer regular build cannot replace the selected stack in the same transaction.
# Explicit targets still install normally (pacman's IgnorePkg prompt defaults yes).
omarchy_arm_package_upgrade_args() {
  local target package names=() targets=()
  mapfile -t targets < <(omarchy_arm_package_targets)
  # These defaults exist only in the explicit upstream repository. Continue
  # updating installed copies, without reinstalling deliberately removed apps.
  for package in asdcontrol tobi-try; do
    if pacman --config "${OMARCHY_PACMAN_CONFIG:-/etc/pacman.conf}" -Q "$package" >/dev/null 2>&1; then
      targets+=("omarchy/$package")
    fi
  done
  for target in "${targets[@]}"; do names+=("${target#*/}"); done
  local IFS=,
  printf '%s\n' --ignore "${names[*]}" "${targets[@]}"
}

omarchy_arm_default_package_target() {
  case "$1" in
    asdcontrol | tobi-try) printf 'omarchy/%s\n' "$1" ;;
    nvim) printf '%s\n' neovim ;;
    *) printf '%s\n' "$1" ;;
  esac
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

omarchy_arm_render_package_sources() {
  local config="$1"
  awk '
    /^[[:space:]]*\[/ { omit = ($0 ~ /^[[:space:]]*\[omarchy\][[:space:]]*(#.*)?$/) }
    !omit { print }
  ' "$config" || return
  omarchy_arm_package_repo
}

omarchy_arm_prepare_package_sources() {
  local config="${1:-/etc/pacman.conf}" backup="${2:-backup}" updated key="40DFB630FF42BCFFB047046CF0134EE680CAC571"
  updated=$(mktemp) || return
  # Replace an existing unrestricted Omarchy section without changing the
  # user's regular repositories, mirror choices, or their ordering.
  omarchy_arm_render_package_sources "$config" > "$updated" || { rm -f "$updated"; return 1; }
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
