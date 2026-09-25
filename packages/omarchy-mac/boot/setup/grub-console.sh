# Apple GRUB compatibility from Marcelo's #208/#209 (979ed031191ee7388d1536cb3ec1a6e583909254).
# Keep the GOP backend the arm64 GRUB ships and wait for an encrypted root
# without systemd's device timeout. Font, theme and splash changes are separate.
omarchy-hw-apple-silicon || return 0
[[ ${OMARCHY_MAC_IMAGE_BUILD:-} != "1" ]] || return 0

(
  grub_default=${OMARCHY_GRUB_DEFAULT:-/etc/default/grub}
  [[ -f $grub_default ]] || exit 0
  pending=${OMARCHY_GRUB_CONSOLE_PENDING:-/var/lib/omarchy/grub-console.pending}
  device_wait='rootflags=x-systemd.device-timeout=0'
  changed=0
  [[ ! -e $pending ]] || changed=1

  # Preserve the last active assignment and collapse duplicates, as upstream.
  grub_console_get() {
    sed -n "s/^$1=//p" "$grub_default" | tail -n 1 | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
  }

  grub_console_set() {
    local key=$1 value=$2 staged
    if [[ $(grub_console_get "$key") == "$value" && $(grep -Ec "^$key=" "$grub_default") == "1" ]]; then
      return 0
    fi
    staged=$(mktemp) || return 1
    if ! awk -v key="$key" -v line="$key=\"$value\"" '
      $0 ~ "^#?" key "=" { if (!done) { print line; done = 1 }; next }
      { print }
      END { if (!done) print line }
    ' "$grub_default" >"$staged"; then
      rm -f "$staged"
      return 1
    fi
    # Journal before changing the defaults: a failed regeneration is retried
    # even if the next run finds the desired values already on disk.
    if ! sudo mkdir -p "$(dirname "$pending")" || ! sudo touch "$pending" ||
      ! sudo cp "$staged" "$grub_default"; then
      rm -f "$staged"
      return 1
    fi
    rm -f "$staged"
    changed=1
  }

  # Unnamed backends also load efi_uga, absent from the arm64 GRUB package.
  grub_console_set GRUB_VIDEO_BACKEND efi_gop || exit 1
  cmdline=$(grub_console_get GRUB_CMDLINE_LINUX)
  if [[ " $cmdline " != *" $device_wait "* ]]; then
    cmdline="${cmdline:+$cmdline }$device_wait"
  fi
  grub_console_set GRUB_CMDLINE_LINUX "$cmdline" || exit 1

  if (( changed )); then
    if omarchy-mac-limine-active; then
      # /etc/default/grub remains the shared command-line source on Limine.
      sudo omarchy-mac-boot-update || exit 1
    elif command -v "${OMARCHY_GRUB_PROBE:-grub-probe}" >/dev/null 2>&1 &&
      command -v "${OMARCHY_GRUB_MKCONFIG:-grub-mkconfig}" >/dev/null 2>&1; then
      sudo "${OMARCHY_UPDATE_GRUB:-update-grub}" >/dev/null || exit 1
    fi
    # Fresh images without GRUB get their first UKI from the following leaf.
    sudo rm -f "$pending" || exit 1
  fi
)
