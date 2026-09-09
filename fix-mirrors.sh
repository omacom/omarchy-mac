#!/bin/bash
# fix-mirrors.sh
# Safe helper to ensure proper pacman configuration and mirrors are set up
# Supports: --replace (force overwrite), --prefer (place Omarchy servers at top),
# --backup (create timestamped backup), --dry-run (show actions, don't write)
# Usage: sudo ./fix-mirrors.sh [--replace] [--prefer] [--backup] [--dry-run]

set -euo pipefail

_fix_mirrors_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! "$_fix_mirrors_root/bin/omarchy-hw-aarch64"; then
  echo "[ERROR] Asahi Alarm requires aarch64 (detected: $("$_fix_mirrors_root/bin/omarchy-hw-arch"))" >&2
  exit 1
fi

OMARCHY_PATH="${OMARCHY_PATH:-$HOME/.local/share/omarchy}"
PACMAN_CONF_SRC="$OMARCHY_PATH/default/pacman/aarch64/pacman.conf"
ASAHI_MIRRORLIST_SRC="$OMARCHY_PATH/default/pacman/aarch64/mirrorlist.asahi-alarm"
SRC="$OMARCHY_PATH/default/pacman/aarch64/mirrorlist"
DEST="/etc/pacman.d/mirrorlist"
ASAHI_MIRRORLIST_DEST="/etc/pacman.d/mirrorlist.asahi-alarm"
PACMAN_ARCH="aarch64"
REPLACE=0
PREFER=0
BACKUP=0
DRYRUN=0
COUNTRY=us
REMOVE_OMARCHY=1

usage() {
  cat <<EOF
Usage: sudo $0 [--replace] [--prefer] [--backup] [--dry-run]

Options:
  --replace   Replace the destination mirrorlist with Omarchy's bundled file (after optional backup).
  --prefer    Ensure Omarchy's Server lines are placed at the top of the mirrorlist (preserve others below).
  --backup    Create a timestamped backup of the destination if it exists.
  --dry-run   Show what would be done without modifying files.

Default behavior: merge Omarchy's Server lines into existing mirrorlist, appending missing entries.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --replace)
      REPLACE=1
      shift
      ;;
    --prefer)
      PREFER=1
      shift
      ;;
    --backup)
      BACKUP=1
      shift
      ;;
    --dry-run)
      DRYRUN=1
      shift
      ;;
    --country)
      COUNTRY=${2:-us}
      shift 2
      ;;
    --remove-omarchy)
      REMOVE_OMARCHY=1
      shift
      ;;
    --keep-omarchy)
      REMOVE_OMARCHY=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ $DRYRUN -eq 1 ]]; then
  echo "[DRYRUN] Would install $PACMAN_CONF_SRC to /etc/pacman.conf"
  echo "[DRYRUN] Would install $ASAHI_MIRRORLIST_SRC to $ASAHI_MIRRORLIST_DEST"
else
  if [[ ! -f $PACMAN_CONF_SRC ]]; then
    echo "[ERROR] Missing pacman config template: $PACMAN_CONF_SRC" >&2
    exit 1
  fi

  if [[ ! -f $ASAHI_MIRRORLIST_SRC ]]; then
    echo "[ERROR] Missing Asahi Alarm mirrorlist template: $ASAHI_MIRRORLIST_SRC" >&2
    exit 1
  fi

  if ! cmp -s "$PACMAN_CONF_SRC" /etc/pacman.conf; then
    echo "Installing new pacman.conf..."
    sudo cp "$PACMAN_CONF_SRC" /etc/pacman.conf
  fi

  sudo cp "$ASAHI_MIRRORLIST_SRC" "$ASAHI_MIRRORLIST_DEST"
fi

if [[ ! -f "$SRC" ]]; then
  echo "[WARN] Omarchy bundled mirrorlist not found at: $SRC (Omarchy server removal will be skipped)" >&2
  SRC=""
fi

if [[ ! -f "$DEST" ]]; then
  echo "[INFO] Destination $DEST does not exist. Will create a mirrorlist with Arch Linux ARM servers."
  if [[ $DRYRUN -eq 1 ]]; then
    echo "[DRYRUN] Would write Arch Linux ARM servers to $DEST"
    exit 0
  fi
  arch_servers=("Server = http://$COUNTRY.mirror.archlinuxarm.org/\$arch/\$repo" "Server = http://mirror.archlinuxarm.org/\$arch/\$repo")
  # Write the servers (simple form)
  tmp=$(mktemp)
  for s in "${arch_servers[@]}"; do
    echo "$s" >>"$tmp"
  done
  sudo cp "$tmp" "$DEST"
  rm -f "$tmp"
  echo "[OK] Created $DEST with appropriate servers for $PACMAN_ARCH architecture"
  exit 0
fi

# At this point, DEST exists.
if [[ $BACKUP -eq 1 ]]; then
  bak="$DEST.bak.$(date +%Y%m%d%H%M%S)"
  if [[ $DRYRUN -eq 1 ]]; then
    echo "[DRYRUN] Would backup $DEST -> $bak"
  else
    sudo cp "$DEST" "$bak"
    echo "[OK] Backed up existing mirrorlist to: $bak"
  fi
fi

if [[ $REPLACE -eq 1 ]]; then
  if [[ $DRYRUN -eq 1 ]]; then
    echo "[DRYRUN] Would replace $DEST with $SRC"
  else
    sudo cp "$SRC" "$DEST"
    echo "[OK] Replaced $DEST with bundled mirrorlist"
  fi
  exit 0
fi

##############################################
# New behavior: prioritize Arch Linux ARM and
# remove Omarchy servers by default
##############################################

# Collect existing server lines from DEST
mapfile -t dest_servers < <(grep -E '^\s*Server\s*=' "$DEST" || true)

normalize() { echo "$1" | sed -E 's/\s+/ /g' | sed -E 's/^\s+|\s+$//g'; }

# Filter out Omarchy servers from dest if requested
filtered_dest=()
for s in "${dest_servers[@]}"; do
  if [[ $REMOVE_OMARCHY -eq 1 ]]; then
    if echo "$s" | grep -qi 'omarchy'; then
      # skip Omarchy servers
      echo "[INFO] Removing Omarchy server from list: $s"
      continue
    fi
  fi
  filtered_dest+=("$s")
done

# Build desired servers based on architecture
arch_servers=("Server = http://$COUNTRY.mirror.archlinuxarm.org/\$arch/\$repo" "Server = http://mirror.archlinuxarm.org/\$arch/\$repo")

# Build set of existing servers for lookup
declare -A have
for s in "${filtered_dest[@]}"; do
  have["$(normalize "$s")"]=1
done

# Find which arch servers are missing
missing_arch=()
for s in "${arch_servers[@]}"; do
  key=$(normalize "$s")
  if [[ -z "${have[$key]:-}" ]]; then
    missing_arch+=("$s")
  fi
done

if [[ ${#missing_arch[@]} -eq 0 && ${#filtered_dest[@]} -eq ${#dest_servers[@]} ]]; then
  echo "[OK] No changes required; appropriate servers for $PACMAN_ARCH present and Omarchy servers removed."
  exit 0
fi

# If prefer, put arch servers at top and then the filtered existing servers
if [[ $PREFER -eq 1 ]]; then
  combined_servers=()
  for s in "${arch_servers[@]}"; do combined_servers+=("$s"); done
  for s in "${filtered_dest[@]}"; do
    key=$(normalize "$s")
    # avoid duplicates
    exists=0
    for cs in "${combined_servers[@]}"; do
      if [[ "$(normalize "$cs")" == "$key" ]]; then
        exists=1
        break
      fi
    done
    if [[ $exists -eq 0 ]]; then combined_servers+=("$s"); fi
  done

  if [[ $DRYRUN -eq 1 ]]; then
    echo "[DRYRUN] Would write preferred servers for $PACMAN_ARCH at top of $DEST:"
    for s in "${combined_servers[@]}"; do echo "  $s"; done
    exit 0
  fi

  tmp=$(mktemp)
  grep -v -E '^\s*Server\s*=' "$DEST" >"$tmp".body || true
  {
    for s in "${combined_servers[@]}"; do echo "$s"; done
    cat "$tmp".body
  } | sudo tee "$DEST" >/dev/null
  rm -f "$tmp".body
  echo "[OK] Wrote preferred servers for $PACMAN_ARCH to $DEST"
  exit 0
fi

# Default: append any missing arch servers after existing filtered servers
if [[ $DRYRUN -eq 1 ]]; then
  echo "[DRYRUN] Would remove Omarchy servers and append missing servers for $PACMAN_ARCH to $DEST"
  echo "[DRYRUN] Servers to append:"
  for s in "${missing_arch[@]}"; do echo "  $s"; done
  exit 0
fi

# Reconstruct DEST: preserve non-Server lines, keep filtered_dest, then append missing_arch
tmp=$(mktemp)
grep -v -E '^\s*Server\s*=' "$DEST" >"$tmp".body || true
{
  for s in "${filtered_dest[@]}"; do echo "$s"; done
  for s in "${missing_arch[@]}"; do echo "$s"; done
  cat "$tmp".body
} | sudo tee "$DEST" >/dev/null
rm -f "$tmp".body

echo "[OK] Updated $DEST: removed Omarchy servers (if any) and ensured appropriate servers for $PACMAN_ARCH present"
exit 0
