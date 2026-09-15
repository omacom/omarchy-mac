# This leaf is also sourced in conditionals: check failures explicitly instead
# of relying on the caller's errexit setting.
configure_snapper_root() {
  local filesystem configs settings name subvolume extra registered=0 other_root=0
  local config_path=${OMARCHY_SNAPPER_CONFIG_PATH:-/etc/snapper/configs/root}
  local template=${OMARCHY_SNAPPER_TEMPLATE:-/etc/snapper/config-templates/omarchy}
  local snapshots_path=${OMARCHY_SNAPPER_SNAPSHOTS_PATH:-/.snapshots}
  local conf_d_path=${OMARCHY_SNAPPER_CONF_PATH:-/etc/conf.d/snapper}

  filesystem=$(stat -f -c %T /) || return $?
  if [[ $filesystem != "btrfs" ]]; then
    echo "Skipping Snapper setup: / is $filesystem, not btrfs."
    return 0
  fi

  configs=$(snapper --no-dbus --csvout list-configs --columns config,subvolume) || return $?
  while IFS=, read -r name subvolume extra; do
    if [[ $name == "root" ]]; then
      if [[ $subvolume != "/" || -n $extra ]]; then
        echo "Error: Snapper root config targets an unexpected subvolume; preserving existing state." >&2
        return 1
      fi
      registered=$((registered + 1))
    elif [[ $subvolume == "/" ]]; then
      other_root=1
    fi
  done <<<"$configs"

  # If a valid root configuration already exists on disk but was not registered in
  # Snapper's global conf.d (e.g. following a fresh package install on an existing setup),
  # register root in conf.d and re-probe so it is recognized instead of treated as a conflict.
  if (( registered == 0 && ! other_root )) && [[ -f $config_path && ! -L $config_path ]]; then
    if settings=$(snapper --no-dbus --csvout -c root get-config --columns key,value 2>/dev/null) &&
      grep -qFx 'FSTYPE,btrfs' <<<"$settings" && grep -qFx 'SUBVOLUME,/' <<<"$settings"; then
      if [[ -f $conf_d_path && ! -L $conf_d_path ]]; then
        if grep -qE '^[[:space:]]*SNAPPER_CONFIGS=' "$conf_d_path"; then
          if ! grep -qE '^[[:space:]]*SNAPPER_CONFIGS=.*(^|[[:space:]"]|\\")root([[:space:]"]|\\"|$)' "$conf_d_path"; then
            sed -i -E 's/^(SNAPPER_CONFIGS="?)([^"]*)("?)/\1\2 root\3/; s/  / /g; s/" root"/"root"/' "$conf_d_path"
          fi
        else
          echo 'SNAPPER_CONFIGS="root"' >> "$conf_d_path"
        fi
      elif [[ ! -e $conf_d_path && -d $(dirname "$conf_d_path") ]]; then
        echo 'SNAPPER_CONFIGS="root"' > "$conf_d_path"
      fi
      configs=$(snapper --no-dbus --csvout list-configs --columns config,subvolume 2>/dev/null) || configs=""
      while IFS=, read -r name subvolume extra; do
        if [[ $name == "root" && $subvolume == "/" && -z $extra ]]; then
          registered=$((registered + 1))
        fi
      done <<<"$configs"
      if (( registered == 0 )) && [[ -e $snapshots_path ]]; then
        registered=1
      fi
    fi
  fi

  if (( registered == 1 && ! other_root )) && [[ -f $config_path && ! -L $config_path ]]; then
    settings=$(snapper --no-dbus --csvout -c root get-config --columns key,value) || return $?
    if ! grep -qFx 'FSTYPE,btrfs' <<<"$settings" || ! grep -qFx 'SUBVOLUME,/' <<<"$settings"; then
      echo "Error: Snapper root config does not describe the btrfs root; preserving existing state." >&2
      return 1
    fi
    # Restore of a nested Btrfs snapshot can leave only an empty placeholder.
    # Repair only the supported Mac @ layout; other working Btrfs layouts and
    # custom mounts retain their existing setup behavior.
    if [[ $(uname -m) == aarch64 && $(findmnt -no FSROOT /) == /@ ]] &&
      [[ ! -L $snapshots_path ]] && ! btrfs subvolume show "$snapshots_path" >/dev/null 2>&1; then
      local backend_helper
      # This leaf also supports the documented standalone sudo bash invocation.
      backend_helper="${OMARCHY_PATH:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}/bin/omarchy-mac-snapper-backend"
      bash "$backend_helper" repair || return $?
    fi
    # A config file alone is not a working backend. Never recreate a partial
    # backend: it may contain snapshots or administrator-managed mounts.
    if [[ -L $snapshots_path ]] || ! btrfs subvolume show "$snapshots_path" >/dev/null; then
      echo "Error: Snapper root snapshot backend is incomplete; preserving it for manual repair." >&2
      return 1
    fi
    snapper --no-dbus -c root list >/dev/null || return $?
    # Setup and the service-repair migration both promise active cleanup,
    # including when an existing root already has custom retention policy.
    systemctl enable --now snapper-cleanup.timer || return $?
    # Limine installs ship this optional unit; Apple/GRUB installs do not.
    if systemctl cat limine-snapper-sync.service >/dev/null 2>&1; then
      systemctl enable --now limine-snapper-sync.service || return $?
    fi
    return 0
  fi

  if (( registered || other_root )) || [[ -e $config_path || -L $config_path || -e $snapshots_path || -L $snapshots_path ]]; then
    echo "Error: Partial or conflicting Snapper root configuration; preserving configs and snapshots for manual repair." >&2
    return 1
  fi

  if [[ ! -r $template ]]; then
    echo "Error: Missing Snapper Omarchy template: $template. Reinstall omarchy-settings and retry." >&2
    return 1
  fi

  # Never change the global timeline timer: other configs may intentionally
  # use it. Snapper owns backend creation and registration, preserving other
  # registered configs, and applies policy only to this new root. The recursive
  # validation below repairs services too, so failed activation stays retryable.
  snapper --no-dbus -c root create-config --template omarchy / || return $?

  [[ -f $config_path && ! -L $config_path && ! -L $snapshots_path ]] || {
    echo "Error: Snapper creation left incomplete state; manual inspection is required." >&2
    return 1
  }
  configure_snapper_root
}

configure_snapper_root
