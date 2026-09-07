SNAPPER_CONFIG_PATH="${OMARCHY_SNAPPER_CONFIG_PATH:-/etc/snapper/configs/root}"
SNAPPER_CONF_PATH="${OMARCHY_SNAPPER_CONF_PATH:-/etc/conf.d/snapper}"
template="${OMARCHY_SNAPPER_TEMPLATE:-${OMARCHY_PATH:-/usr/share/omarchy}/default/snapper/root}"

echo "Configuring Omarchy Snapper snapshot retention"

snapper_configured=1
snapper_root_filesystem=$(stat -f -c %T /)

if [[ ! -f $SNAPPER_CONFIG_PATH ]]; then
  mkdir -p "$(dirname "$SNAPPER_CONFIG_PATH")"

  if [[ ${OMARCHY_SNAPPER_CONFIGURE_TEST:-0} == "1" ]]; then
    : >"$SNAPPER_CONFIG_PATH"
  elif [[ $snapper_root_filesystem != "btrfs" ]]; then
    # Omarchy's root snapshot policy uses btrfs; older installs may use ext4.
    snapper_configured=0
  elif snapper --no-dbus -c root create-config /; then
    :
  else
    snapper_status=$?
    echo "Error: Snapper root configuration failed on btrfs (exit $snapper_status). See the command output above." >&2
    # This leaf is sourced by the logged setup runner under errexit. Preserve
    # the backend error instead of claiming a missing/broken Snapper is ext4.
    (exit "$snapper_status")
  fi
fi

if (( snapper_configured )); then
  install -m 0644 "$template" "$SNAPPER_CONFIG_PATH"

  mkdir -p "$(dirname "$SNAPPER_CONF_PATH")"
  printf '%s\n' 'SNAPPER_CONFIGS="root"' >"$SNAPPER_CONF_PATH"
  chmod 0644 "$SNAPPER_CONF_PATH"

  systemctl disable --now snapper-timeline.timer >/dev/null 2>&1 || true
  systemctl enable --now snapper-cleanup.timer >/dev/null 2>&1 || true

  # limine-snapper-sync exists only on x86 Limine installs; Macs boot via GRUB.
  if systemctl cat limine-snapper-sync.service >/dev/null 2>&1; then
    systemctl enable --now limine-snapper-sync.service >/dev/null 2>&1 || true
  fi
else
  echo "Skipping Snapper setup: / is $snapper_root_filesystem, not btrfs."
fi
