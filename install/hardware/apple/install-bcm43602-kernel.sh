install_apple_bcm43602_kernel() {
  local boot_available_kib boot_space_output minimum_boot_kib=262144
  local limine_dir="${OMARCHY_BCM43602_LIMINE_DIR:-/etc/limine-entry-tool.d}"
  local policy_file="$limine_dir/zz-apple-bcm43602.conf"
  local policy_tmp

  omarchy-hw-apple-bcm43602 || return 0
  omarchy-hw-apple-bcm43602 --ready && return 0

  echo "Detected Apple BCM43602 Wi-Fi"

  if [[ -n ${OMARCHY_BCM43602_BOOT_AVAILABLE_KIB:-} ]]; then
    boot_available_kib="$OMARCHY_BCM43602_BOOT_AVAILABLE_KIB"
  else
    if ! boot_space_output=$(df --output=avail -k "${OMARCHY_BCM43602_BOOT_PATH:-/boot}"); then
      echo "Error: could not determine free space on /boot" >&2
      return 1
    fi
    boot_available_kib="${boot_space_output##*$'\n'}"
    boot_available_kib="${boot_available_kib//[[:space:]]/}"
  fi

  # The live-tested UKI uses less than half of this allowance. Keep the rest
  # available for the stock-kernel fallback and atomic boot-image replacement.
  if [[ ! $boot_available_kib =~ ^[0-9]+$ ]] || (( boot_available_kib < minimum_boot_kib )); then
    echo "Error: linux-bcm43602 requires at least 256 MiB free on /boot while retaining the stock kernel" >&2
    return 1
  fi

  if omarchy-pkg-missing linux-bcm43602 linux-bcm43602-headers; then
    omarchy-pkg-add linux-bcm43602 linux-bcm43602-headers
    if omarchy-pkg-missing linux-bcm43602 linux-bcm43602-headers; then
      echo "Error: linux-bcm43602 and its headers were not fully installed" >&2
      return 1
    fi
  fi

  mkdir -p "$limine_dir"
  policy_tmp=$(mktemp "$limine_dir/.zz-apple-bcm43602.conf.XXXXXX")
  cat >"$policy_tmp" <<'EOF'
# Prefer the BCM43602 resume kernel and retain stock Linux as a bootable fallback
BOOT_ORDER="linux-bcm43602*, linux*, *fallback, Snapshots"
EOF
  chmod 644 "$policy_tmp"
  mv -f "$policy_tmp" "$policy_file"

  limine-mkinitcpio
  if ! omarchy-hw-apple-bcm43602 --ready; then
    echo "Error: candidate and stock boot entries were not generated correctly" >&2
    return 1
  fi

}

install_apple_bcm43602_kernel
