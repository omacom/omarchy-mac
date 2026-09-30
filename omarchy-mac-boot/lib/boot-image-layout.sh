# Sourced by omarchy-apple-silicon-boot-check and provision.sh; do not run
# independently. Whether an extracted boot image types the disk passphrase with
# the keyboard layout /etc/vconsole.conf sets now.
#
# The file alone loads nothing: on a systemd image the console prompt needs
# systemd-vconsole-setup, loadkeys and the KEYMAP file (sd-vconsole), on a
# busybox image the keymap.bin the keymap hook compiles, and Plymouth, which
# reads keys through evdev, needs the XKB symbols of each XKBLAYOUT (the
# plymouth hook). Those files must be there too; that proves they were
# bundled, not that every file they include is.

# One setting of a vconsole.conf, read in a clean shell.
vconsole_value() {
  env -i PATH=/usr/bin:/bin bash --noprofile --norc -c '
    unset "$1"
    . "$2" >/dev/null 2>&1
    printf "%s" "${!1:-}"
  ' _ "$1" "$2"
}

# The keyboard settings of a vconsole.conf; comments and fonts do not count.
vconsole_keyboard() {
  local key
  for key in KEYMAP KEYMAP_TOGGLE XKBLAYOUT XKBMODEL XKBVARIANT XKBOPTIONS; do
    printf '%s=%s\n' "$key" "$(vconsole_value "$key" "$1")"
  done
}

# Succeeds when the boot image must carry this vconsole.conf: a layout other
# than US that types Latin letters. The others are left out of the image on
# purpose (94-omarchy-mac-vconsole.conf), so the prompt uses the kernel's map.
vconsole_layout_carried() {
  local keymap layout
  [[ -f $1 ]] || return 1
  keymap=$(vconsole_value KEYMAP "$1")
  layout=$(vconsole_value XKBLAYOUT "$1")
  case ${layout%%,*} in
    af | am | ara | bd | bg | by | et | ge | gr | il | in | iq | ir | kg | kh | kz | la | lk | mk | mm | mn | mv | np | rs | ru | sy | th | tj | ua) return 1 ;;
  esac
  [[ ${keymap:-us} != us || ${layout:-us} != us ]]
}

# boot_image_carries_vconsole <extracted image> <vconsole.conf>
boot_image_carries_vconsole() {
  [[ -f $1/etc/vconsole.conf && $(vconsole_keyboard "$1/etc/vconsole.conf") == "$(vconsole_keyboard "$2")" ]]
}

# boot_image_layout_missing <extracted image> <vconsole.conf> <busybox 0|1>
# Prints, one per line, what the image lacks to load that layout at the prompt.
boot_image_layout_missing() {
  local dir=$1 keymap layout tool found suffix compression file xkb_layout
  local -a xkb_layouts=()
  keymap=$(vconsole_value KEYMAP "$2")
  layout=$(vconsole_value XKBLAYOUT "$2")

  if (( $3 )); then
    # The keymap hook compiles KEYMAP into keymap.bin when the image is built.
    case ${keymap:-us} in
      us | @kernel) ;;
      *) [[ -f $dir/keymap.bin ]] || echo "the keymap hook's keymap.bin" ;;
    esac
  else
    for tool in usr/lib/systemd/systemd-vconsole-setup usr/bin/loadkeys; do
      [[ -e $dir/$tool || -L $dir/$tool ]] || echo "/$tool"
    done
    # The lookup sd-vconsole makes when it builds the image: the name, which
    # may carry directories, under /usr/share/kbd/keymaps, then an optional
    # .map or .inc and an optional compression suffix. An absolute KEYMAP is
    # taken as it is. Only the file itself is checked, not the files it
    # includes.
    case ${keymap:-us} in
      us | @kernel) ;;
      /*) [[ -e $dir$keymap ]] || echo "$keymap" ;;
      *)
        found=0
        while IFS= read -r -d '' file; do
          for suffix in "" .map .inc; do
            for compression in "" .gz .bz2 .zst; do
              [[ $file == */"$keymap$suffix$compression" ]] && found=1
            done
          done
        done < <(find "$dir/usr/share/kbd/keymaps" -type f -print0 2>/dev/null)
        (( found )) || echo "the $keymap keymap"
        ;;
    esac
  fi

  if [[ -e $dir/usr/bin/plymouthd && -n $layout ]]; then
    IFS=, read -r -a xkb_layouts <<<"$layout"
    for xkb_layout in "${xkb_layouts[@]}"; do
      [[ -z $xkb_layout || -e $dir/usr/share/X11/xkb/symbols/$xkb_layout ]] ||
        echo "the XKB symbols for $xkb_layout"
    done
  fi
  return 0
}

# boot_image_layout_loads <extracted image> <vconsole.conf>
# The console keymaps load with the image's own loadkeys and keymap files, and
# the XKB layout Plymouth compiles builds from the image's own XKB data. Prints
# what does not and fails. Runs as root (chroot); xkbcli comes with
# libxkbcommon, which Plymouth depends on.
boot_image_layout_loads() {
  local dir=$1 keymap setting value names=""
  local -a xkb=(--test --include "$dir/usr/share/X11/xkb" --rules evdev)
  for keymap in "$(vconsole_value KEYMAP "$2")" "$(vconsole_value KEYMAP_TOGGLE "$2")"; do
    [[ -n $keymap && $keymap != @kernel ]] || continue
    chroot "$dir" /usr/bin/loadkeys -q -b "$keymap" >/dev/null 2>&1 || {
      echo "the console keymap $keymap"
      return 1
    }
  done
  [[ -e $dir/usr/bin/plymouthd && -n $(vconsole_value XKBLAYOUT "$2") ]] || return 0
  for setting in XKBMODEL:--model XKBLAYOUT:--layout XKBVARIANT:--variant XKBOPTIONS:--options; do
    value=$(vconsole_value "${setting%%:*}" "$2")
    [[ -z $value ]] || xkb+=("${setting#*:}" "$value") names+=" ${setting%%:*}=$value"
  done
  xkbcli compile-keymap "${xkb[@]}" >/dev/null 2>&1 || {
    echo "the XKB layout${names}"
    return 1
  }
}
