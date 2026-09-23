#!/bin/bash

# Persist a console keymap and its desktop XKB equivalent. The setup form owns
# the mapping used by the ISO and first-boot owner setup.
set -euo pipefail

apply_keyboard_layout() {
  local keymap=$1 script_dir row xkb_layout xkb_variant vconsole
  [[ $keymap =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]*$ ]] || {
    echo "Invalid console keymap: $keymap" >&2
    return 1
  }
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  source "$script_dir/../provisioning/setup-form.sh"

  row=$(awk -F'|' -v keymap="$keymap" 'tolower($2) == tolower(keymap) { print; exit }' <<<"$OMARCHY_KEYBOARD_LAYOUTS")
  if [[ -n $row ]]; then
    IFS='|' read -r _ _ xkb_layout xkb_variant <<<"$row"
  else
    xkb_layout=""
    xkb_variant=""
  fi

# localectl normally converts the console choice to XKB. The shared form's
# mapping is authoritative for the layouts it offers, including uk -> gb.
  if ! localectl set-keymap "$keymap" >/dev/null 2>&1; then
    systemd-firstboot --keymap="$keymap" --force >/dev/null 2>&1 || {
      echo "Could not persist console keymap $keymap" >&2
      return 1
    }
  fi

  if [[ -z $xkb_layout ]]; then
    xkb_layout=$(localectl status 2>/dev/null | sed -n 's/^[[:space:]]*X11 Layout:[[:space:]]*//p' | head -1)
    xkb_variant=$(localectl status 2>/dev/null | sed -n 's/^[[:space:]]*X11 Variant:[[:space:]]*//p' | head -1)
    [[ -n $xkb_layout && $xkb_layout != "n/a" && $xkb_layout != "(unset)" ]] || {
      echo "Could not determine desktop layout for console keymap $keymap" >&2
      return 1
    }
    [[ $xkb_variant != "n/a" && $xkb_variant != "(unset)" ]] || xkb_variant=""
  fi

  localectl --no-convert set-x11-keymap "$xkb_layout" "" "$xkb_variant" >/dev/null 2>&1 || true

# Hyprland reads these keys from vconsole.conf. localectl writes XKB to an X11
# config file on some systems, so put them here explicitly as first boot does.
  vconsole=${OMARCHY_VCONSOLE_CONF:-/etc/vconsole.conf}
  touch "$vconsole"
  sed -i '/^KEYMAP=/d; /^XKBLAYOUT=/d; /^XKBVARIANT=/d' "$vconsole"
  printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$keymap" "$xkb_layout" >>"$vconsole"
  if [[ -n $xkb_variant ]]; then
    printf 'XKBVARIANT=%s\n' "$xkb_variant" >>"$vconsole"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  (( EUID == 0 )) || { echo "Keyboard layout setup requires root" >&2; exit 1; }
  (( $# == 1 )) || { echo "Usage: apply-keyboard-layout.sh KEYMAP" >&2; exit 1; }
  apply_keyboard_layout "$1"
fi
