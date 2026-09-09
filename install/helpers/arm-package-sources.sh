#!/bin/bash

# Shared by the standalone installer and installed package update commands.
omarchy_arm_package_targets() {
  printf '%s\n' omarchy/hyprland omarchy/hyprtoolkit omarchy/hyprland-guiutils
}

# --needed drops unchanged explicit targets before sysupgrade considers the
# regular repositories. Exclude those names from that implicit upgrade so a
# newer regular build cannot replace the selected stack in the same transaction.
# Explicit targets still install normally (pacman's IgnorePkg prompt defaults yes).
omarchy_arm_package_upgrade_args() {
  local target names=()
  while read -r target; do
    names+=("${target#*/}")
  done < <(omarchy_arm_package_targets)
  local IFS=,
  printf '%s\n' --ignore "${names[*]}"
  omarchy_arm_package_targets
}

omarchy_arm_package_is_selected() {
  local target
  while read -r target; do
    [[ ${target#*/} == "$1" ]] && return 0
  done < <(omarchy_arm_package_targets)
  return 1
}

omarchy_arm_channel_url() {
  case "$1" in
    stable|rc|edge) printf 'https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/channel-%s\n' "$1" ;;
    *) echo "Invalid ARM package channel: $1" >&2; return 1 ;;
  esac
}

# Identity comes from the managed Mac repository, never ALARM's mirror or the
# official compositor source. The legacy edge endpoint served stable clients.
omarchy_arm_package_channel() {
  local config="${1:-/etc/pacman.conf}" url channel
  url=$(awk '
    /^[[:space:]]*\[/ { selected = ($0 ~ /^[[:space:]]*\[omarchy-aarch64\][[:space:]]*$/) }
    selected && /^[[:space:]]*Server[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); print }
  ' "$config")
  for channel in stable rc edge; do
    if [[ $url == "$(omarchy_arm_channel_url "$channel")" ]]; then
      printf '%s\n' "$channel"
      return 0
    fi
  done
  if [[ $url == "https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge" ]]; then
    echo stable
  else
    echo "Cannot determine ARM package channel from $config" >&2
    return 1
  fi
}

omarchy_arm_validate_channel() {
  local channel="$1" helper_root="${2:-${OMARCHY_PATH:-}}" url
  [[ -n $helper_root ]] || { echo "Omarchy source path is required" >&2; return 1; }
  url=$(omarchy_arm_channel_url "$channel") || return
  python3 "$helper_root/install/helpers/arm-channel-manifest.py" "$channel" "$url"
}

omarchy_arm_package_repo() {
  local url
  url=$(omarchy_arm_channel_url "$1") || return
  # The managed snapshot carries both aliases, so existing qualified compositor
  # targets and automatic overlay updates resolve to the same frozen artifacts.
  printf '%s\n' '[omarchy]' 'Usage = Sync' 'SigLevel = Required DatabaseOptional' "Server = $url" '' \
    '[omarchy-aarch64]' 'SigLevel = Optional TrustAll' "Server = $url"
}

omarchy_arm_prepare_package_sources() {
  local config="${1:-/etc/pacman.conf}" backup="${2:-backup}" channel="${3:-}" helper_root="${4:-${OMARCHY_PATH:-}}" updated key="40DFB630FF42BCFFB047046CF0134EE680CAC571"
  if [[ -z $channel ]]; then
    channel=$(omarchy_arm_package_channel "$config") || return
  fi
  omarchy_arm_validate_channel "$channel" "$helper_root" || return
  # Imported official packages keep their detached signatures. Fresh ALARM
  # installations need the existing Omarchy package key before using them.
  if ! sudo pacman-key --list-keys "$key" >/dev/null 2>&1; then
    sudo pacman-key --recv-keys "$key" --keyserver hkps://keys.openpgp.org || return
  fi
  sudo pacman-key --lsign-key "$key" || return
  updated=$(mktemp) || return
  # Put the managed overlay before the base repos so its frozen dependencies
  # cannot be silently selected from a different channel or rolling base.
  awk '
    BEGIN { repos=0 }
    /^[[:space:]]*\[/ && $0 !~ /^[[:space:]]*\[options\]/ { repos=1 }
    !repos { print }
  ' "$config" > "$updated"
  omarchy_arm_package_repo "$channel" >> "$updated" || { rm -f "$updated"; return 1; }
  awk '
    /^[[:space:]]*\[/ { repos=($0 !~ /^[[:space:]]*\[options\]/); omit=($0 ~ /^[[:space:]]*\[omarchy(-aarch64)?\][[:space:]]*(#.*)?$/) }
    repos && !omit { print }
  ' "$config" >> "$updated"
  if ! cmp -s "$config" "$updated"; then
    if [[ $backup != "preserve-backup" ]]; then
      sudo cp "$config" "$config.bak" || { rm -f "$updated"; return 1; }
    fi
    sudo install -m 644 "$updated" "$config" || { rm -f "$updated"; return 1; }
  fi
  rm -f "$updated"
}
