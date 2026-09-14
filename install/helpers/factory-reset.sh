# Shared factory-reset inventory and current-code delivery. Sourced by the
# staging command and its first-boot worker; no action is performed on source.

reset_error() { echo "Error: $*" >&2; return 1; }
reset_uuid() {
  local info identity
  [[ ! -L $1 && -d $1 ]] || return 1
  info=$(LC_ALL=C btrfs subvolume show "$1") || return $?
  identity=$(awk '$1=="UUID:" {print $2; exit}' <<<"$info")
  [[ $identity =~ ^[a-fA-F0-9-]{36}$ ]] || return 1
  printf '%s\n' "$identity"
}
reset_default_identity() {
  local top=$1 row path identity
  row=$(LC_ALL=C btrfs subvolume get-default "$top") || return $?
  if [[ $row == 'ID 5 (FS_TREE)' ]]; then
    printf '%s\t%s\n' - -
    return 0
  fi
  [[ $row == ID\ *\ gen\ *\ top\ level\ *\ path\ * ]] || return 1
  path=${row#* path }
  reset_safe_path "$path" || return 1
  identity=$(reset_uuid "$top/$path") || return $?
  printf '%s\t%s\n' "$identity" "$path"
}
reset_default_uuid() {
  local identity path extra
  IFS=$'\t' read -r identity path extra < <(reset_default_identity "$1") || return $?
  [[ -z $extra ]] || return 1
  printf '%s\n' "$identity"
}
reset_default_set() {
  local top=$1 expected=$2 path=$3
  [[ $expected =~ ^[a-fA-F0-9-]{36}$ && $path == "$top/"* && $(reset_uuid "$path") == "$expected" ]] || return 1
  btrfs subvolume set-default "$path" || return $?
  [[ $(reset_default_uuid "$top") == "$expected" ]]
}
reset_default_set_top() {
  local top=$1
  btrfs subvolume set-default 5 "$top" || return $?
  [[ $(reset_default_uuid "$top") == - ]]
}
reset_default_restore() {
  local top=$1 expected=$2 path=$3
  if [[ $expected == - && $path == - ]]; then
    reset_default_set_top "$top"
  else
    reset_safe_path "$path" && reset_default_set "$top" "$expected" "$top/$path"
  fi
}
reset_default_in_inventory() {
  local manifest=$1 identity=$2 path=$3
  [[ $identity == - && $path == - ]] && return 0
  [[ $identity =~ ^[a-fA-F0-9-]{36}$ ]] && reset_safe_path "$path" || return 1
  awk -F '\t' -v identity="$identity" -v path="$path" '
    $1 == identity && $2 == path { matches++ }
    END { exit(matches == 1 ? 0 : 1) }
  ' "$manifest"
}
reset_safe_path() {
  [[ $1 =~ ^[a-zA-Z0-9@._/-]+$ && $1 != /* && $1 != */ && $1 != *//* && /$1/ != */../* && /$1/ != */./* ]]
}
reset_nested_paths() {
  local listing line path
  listing=$(LC_ALL=C btrfs subvolume list -o "$1") || return $?
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    [[ $line == ID\ *\ path\ * ]] || return 1
    path=${line#* path }
    path=${path#<FS_TREE>/}
    reset_safe_path "$path" || return 1
    printf '%s\n' "$path"
  done <<<"$listing"
}
reset_inventory_add() {
  local top=$1 source=$2 destination=$3 role=$4 manifest=$5 path identity relative nested child entry_role
  reset_safe_path "$source" && reset_safe_path "$destination" || return 1
  # list -o reports direct children, not the complete descendant tree. Walk
  # each child's own list so nested Snapper snapshots are explicitly authorized.
  local -a pending=("$source")
  local -A seen=()
  while (( ${#pending[@]} )); do
    path=${pending[0]}
    pending=("${pending[@]:1}")
    [[ ! ${seen[$path]+yes} ]] || continue
    seen[$path]=1
    identity=$(reset_uuid "$top/$path") || return $?
    if [[ $path == "$source" ]]; then
      relative="" entry_role=$role
    else
      relative="/${path#"$source/"}" entry_role="nested-$role"
    fi
    printf '%s\t%s\t%s%s\t%s\n' "$identity" "$path" "$destination" "$relative" "$entry_role" >>"$manifest" || return $?
    nested=$(reset_nested_paths "$top/$path") || return $?
    while IFS= read -r child; do
      [[ -n $child ]] || continue
      [[ $child == "$path/"* ]] || { reset_error "Unexpected nested subvolume: $child"; return 1; }
      pending+=("$child")
    done <<<"$nested"
  done
}

reset_inventory_build() {
  local top=$1 stamp=$2 manifest=$3 candidate
  [[ $stamp =~ ^[0-9]+$ && ! -e $manifest && ! -L $manifest ]] || return 1
  (umask 077; set -o noclobber; : >"$manifest") || return $?
  reset_inventory_add "$top" @ "@omarchy-old-$stamp" current-root "$manifest" || return $?
  reset_inventory_add "$top" @factory "@omarchy-old-factory-$stamp" factory-baseline "$manifest" || return $?
  for candidate in @home @log @fresh; do
    [[ -e $top/$candidate || -L $top/$candidate ]] || continue
    reset_inventory_add "$top" "$candidate" "$candidate" "$candidate" "$manifest" || return $?
  done
  for candidate in "$top"/@old-* "$top"/@omarchy-old-*; do
    [[ -e $candidate || -L $candidate ]] || continue
    reset_inventory_add "$top" "${candidate##*/}" "${candidate##*/}" legacy-retained-root "$manifest" || return $?
  done
  reset_inventory_validate "$manifest" || return $?
  sync -f "$manifest"
}
reset_inventory_validate() {
  local manifest=$1 identity source destination role extra
  [[ -f $manifest && ! -L $manifest && $(stat -c %u "$manifest") == 0 && $(stat -c %a "$manifest") == 600 ]] || return 1
  local -A identities=() destinations=()
  while IFS=$'\t' read -r identity source destination role extra; do
    [[ $identity =~ ^[a-fA-F0-9-]{36}$ && -z $extra && -n $role ]] || return 1
    reset_safe_path "$source" && reset_safe_path "$destination" || return 1
    [[ ! ${identities[$identity]+present} && ! ${destinations[$destination]+present} ]] || return 1
    [[ $destination != @ && $destination != @factory ]] || return 1
    identities[$identity]=1 destinations[$destination]=1
  done <"$manifest"
  (( ${#identities[@]} > 0 ))
}
reset_inventory_verify_sources() {
  local top=$1 manifest=$2 identity source destination role nested path
  local -A planned=()
  reset_inventory_validate "$manifest" || return $?
  while IFS=$'\t' read -r identity source destination role; do
    [[ $(reset_uuid "$top/$source") == "$identity" ]] || { reset_error "Reset source identity changed: $source"; return 1; }
    if [[ $source != "$destination" && (-e $top/$destination || -L $top/$destination) ]]; then
      reset_error "Reset destination already exists: $destination"
      return 1
    fi
    planned[$source]=$identity
  done <"$manifest"
  while IFS=$'\t' read -r identity source destination role; do
    nested=$(reset_nested_paths "$top/$source") || return $?
    while IFS= read -r path; do
      [[ -z $path ]] && continue
      [[ ${planned[$path]+yes} && $(reset_uuid "$top/$path") == "${planned[$path]}" ]] || {
        reset_error "Unconfirmed descendant appeared: $path"; return 1;
      }
    done <<<"$nested"
  done <"$manifest"
}
reset_inventory_display() {
  local manifest=$1 identity source destination role
  echo "The following exact subvolumes, including every listed nested subvolume, will be erased:"
  while IFS=$'\t' read -r identity source destination role; do
    printf '  %-34s %s  [%s]\n' "$source" "$identity" "$role"
  done <"$manifest"
  echo "Legacy names are not ownership proof: confirm only if every listed identity is intended for deletion."
  echo "Other administrator subvolumes and filesystems are outside this reset and remain untouched."
}
reset_assert_unmounted() {
  local top=$1 path=$2 filesystem_uuid=$3 mounts target uuid fsroot extra
  mounts=$(findmnt -rn --raw -o TARGET,UUID,FSROOT) || return $?
  while read -r target uuid fsroot extra; do
    [[ $target != "$top/$path" && $target != "$top/$path/"* ]] || { reset_error "Mounted cleanup descendant: $target"; return 1; }
    if [[ $uuid == "$filesystem_uuid" && ($fsroot == "/$path" || $fsroot == "/$path/"*) ]]; then
      reset_error "Cleanup subvolume is mounted at $target: $path"
      return 1
    fi
  done <<<"$mounts"
}
reset_private_file() {
  [[ -f $1 && ! -L $1 && $(stat -c %u "$1") == 0 && $(stat -c %a "$1") == 600 ]]
}
reset_state_write() {
  local target=$1 value=$2 temporary
  [[ ! -L $target && (! -e $target || -f $target) ]] || return 1
  temporary=$(mktemp "${target}.new.XXXXXXXX") || return $?
  if ! { chmod 600 "$temporary" && printf '%s\n' "$value" >"$temporary" && sync -f "$temporary" && mv -T "$temporary" "$target" && sync -f "${target%/*}"; }; then
    rm -f "$temporary"
    return 1
  fi
}
reset_state_bind() {
  local manifest=$1 state=$2 filesystem_uuid=$3 digest expected contents
  [[ $filesystem_uuid =~ ^[a-fA-F0-9-]{36}$ ]] || return 1
  [[ ! -L $state && (! -e $state || -d $state) ]] || return 1
  if [[ -e $state ]]; then
    [[ $(stat -c %u "$state") == 0 && $(stat -c %a "$state") == 700 ]] || return 1
  else
    install -d -m 700 "$state" || return $?
  fi
  digest=$(sha256sum "$manifest") || return $?
  expected="$filesystem_uuid ${digest%% *}"
  if [[ -e $state/binding || -L $state/binding ]]; then
    reset_private_file "$state/binding" && [[ $(cat "$state/binding") == "$expected" ]] || return 1
  else
    # Refuse pre-existing progress without a binding, including a failed bind.
    contents=$(find "$state" -mindepth 1 -maxdepth 1 -print -quit) || return $?
    [[ -z $contents ]] || return 1
    reset_state_write "$state/binding" "$expected" || return $?
  fi
}
reset_row_state() {
  local top=$1 state=$2 identity=$3 destination=$4 marker="$2/$3" current replacement
  RESET_ROW_PRESENT=0
  [[ ! -e $marker && ! -L $marker ]] || reset_private_file "$marker" || return 1
  if [[ ! -e $top/$destination && ! -L $top/$destination ]]; then
    [[ -f $marker && ($(cat "$marker") == "intent $destination" || $(cat "$marker") == "done $destination") ]] || {
      reset_error "Cleanup path vanished without its deletion receipt: $destination"; return 1;
    }
    return 0
  fi
  current=$(reset_uuid "$top/$destination") || return $?
  if [[ $current == "$identity" ]]; then
    [[ ! -e $marker || $(cat "$marker") == "intent $destination" ]] || return 1
    RESET_ROW_PRESENT=1
    return 0
  fi
  # Home/log replacements belong to this operation only after their UUID was
  # durably recorded. An arbitrary replacement never inherits authorization.
  [[ $destination == @home || $destination == @log ]] || return 1
  replacement="$state/replacement-${destination#@}"
  reset_private_file "$marker" && [[ $(cat "$marker") == "done $destination" ]] || return 1
  reset_private_file "$replacement" && [[ $(cat "$replacement") == "$current $destination" ]] || {
    reset_error "Cleanup identity changed: $destination"; return 1;
  }
}
reset_cleanup_preflight() {
  local top=$1 manifest=$2 state=$3 filesystem_uuid=$4 identity source destination role nested path default_uuid
  local -A planned=()
  reset_inventory_validate "$manifest" && reset_state_bind "$manifest" "$state" "$filesystem_uuid" || return $?
  default_uuid=$(reset_default_uuid "$top") || return $?
  while IFS=$'\t' read -r identity source destination role; do
    [[ $default_uuid == - || $identity != "$default_uuid" ]] || {
      reset_error "Refusing to delete the default subvolume: $destination"; return 1;
    }
    planned[$destination]=$identity
  done <"$manifest"
  while IFS=$'\t' read -r identity source destination role; do
    reset_row_state "$top" "$state" "$identity" "$destination" || return $?
    (( RESET_ROW_PRESENT )) || continue
    reset_assert_unmounted "$top" "$destination" "$filesystem_uuid" || return $?
    nested=$(reset_nested_paths "$top/$destination") || return $?
    while IFS= read -r path; do
      [[ -z $path ]] && continue
      [[ ${planned[$path]+yes} && $(reset_uuid "$top/$path") == "${planned[$path]}" ]] || {
        reset_error "Unconfirmed cleanup descendant: $path"; return 1;
      }
    done <<<"$nested"
  done <"$manifest"
}
reset_cleanup_inventory() {
  local top=$1 manifest=$2 state=$3 filesystem_uuid=$4 identity source destination role marker nested ordered
  reset_cleanup_preflight "$top" "$manifest" "$state" "$filesystem_uuid" || return $?
  # Inspect the whole inventory before deleting anything, then recheck each
  # row immediately before its non-recursive deletion. New children stop it.
  ordered=$(awk -F '\t' '{n=split($3,p,"/"); print n "\t" $0}' "$manifest" | LC_ALL=C sort -t $'\t' -k1,1nr | cut -f2-) || return $?
  while IFS=$'\t' read -r identity source destination role; do
    marker="$state/$identity"
    reset_row_state "$top" "$state" "$identity" "$destination" || return $?
    if (( ! RESET_ROW_PRESENT )); then
      if [[ ! -e $top/$destination && ! -L $top/$destination ]]; then
        reset_state_write "$marker" "done $destination" || return $?
      fi
      continue
    fi
    reset_assert_unmounted "$top" "$destination" "$filesystem_uuid" || return $?
    nested=$(reset_nested_paths "$top/$destination") || return $?
    [[ -z $nested ]] || { reset_error "Unremoved or unlisted child under $destination; preserving it"; return 1; }
    reset_state_write "$marker" "intent $destination" || return $?
    btrfs subvolume delete "$top/$destination" || return $?
    reset_state_write "$marker" "done $destination" || return $?
  done <<<"$ordered"
}
reset_empty_volume() {
  local contents
  contents=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit) || return $?
  [[ -z $contents ]]
}
reset_recreate_clean_subvolume() {
  local top=$1 name=$2 state=$3 identity marker="$3/replacement-${2#@}" temporary="$1/@omarchy-reset-${2#@}"
  [[ $name == @home || $name == @log ]] || return 1
  if [[ -e $top/$name || -L $top/$name ]]; then
    identity=$(reset_uuid "$top/$name") || return $?
    reset_private_file "$marker" && [[ $(cat "$marker") == "$identity $name" && ! -e $temporary && ! -L $temporary ]] || {
      reset_error "Unrecorded replacement at $name; inspect before retry"; return 1;
    }
    return 0
  fi
  if [[ -e $marker || -L $marker ]]; then
    reset_private_file "$marker" || return 1
    identity=$(reset_uuid "$temporary") || return $?
    [[ $(cat "$marker") == "$identity $name" ]] || return 1
    reset_empty_volume "$temporary" || return $?
  else
    [[ ! -e $temporary && ! -L $temporary ]] || return 1
    btrfs subvolume create "$temporary" || return $?
    identity=$(reset_uuid "$temporary") || return $?
    if ! reset_state_write "$marker" "$identity $name"; then
      # Only this process's just-created, still-empty exact UUID can be
      # removed on a receipt failure. Unknown leftover state is preserved.
      if [[ $(reset_uuid "$temporary") == "$identity" ]] && reset_empty_volume "$temporary"; then
        btrfs subvolume delete "$temporary" || return $?
      fi
      return 1
    fi
  fi
  mv -T "$temporary" "$top/$name" || return $?
  [[ $(reset_uuid "$top/$name") == "$identity" ]] || return 1
  sync -f "$top"
}
reset_closure_files() {
  printf '%s\n' \
    bin/omarchy-system-factory-reset \
    bin/omarchy-system-factory-reset-finish \
    bin/omarchy-mac-snapper-backend \
    bin/omarchy-update-lock \
    bin/omarchy-provision-owner \
    install/helpers/factory-reset.sh \
    install/helpers/browser-policy.sh \
    install/helpers/as-root.sh \
    install/helpers/reset-boot.sh \
    install/helpers/owner-rekey.sh \
    install/provisioning/setup-form.sh \
    install/provisioning/omarchy-system-factory-reset-finish.service \
    install/provisioning/omarchy-provision-owner.service \
    logo.txt
}
reset_closure_preflight() {
  local source=$1 root=$2 file tool directory
  for directory in etc var var/lib home root usr usr/bin usr/share usr/share/omarchy; do
    [[ -d $root/$directory && ! -L $root/$directory ]] || return 1
  done
  for directory in etc/ssh etc/NetworkManager etc/NetworkManager/system-connections etc/omarchy etc/sddm.conf.d etc/mkinitcpio.conf.d etc/default etc/default/grub.d etc/limine-entry-tool.d var/lib/omarchy var/lib/omarchy/provisioning var/lib/NetworkManager var/lib/sddm var/lib/tailscale var/lib/iwd var/lib/fprint; do
    [[ ! -L $root/$directory && (! -e $root/$directory || -d $root/$directory) ]] || {
      reset_error "Unsupported factory identity-state path: $directory"; return 1;
    }
  done
  while IFS= read -r file; do
    [[ -f $source/$file && ! -L $source/$file ]] || { reset_error "Missing current reset closure file: $file"; return 1; }
  done < <(reset_closure_files)
  for tool in bash btrfs findmnt mount umount systemctl chroot sha256sum awk sort cut install useradd userdel usermod groupadd passwd runuser gum cryptsetup jq flock pgrep; do
    [[ -x $root/usr/bin/$tool ]] || { reset_error "Factory baseline lacks required tool: $tool"; return 1; }
  done
  [[ -x $root/usr/bin/omarchy-provision-user && -r $root/usr/share/omarchy/install/user/all.sh ]] || return 1
  grep -q omarchy-update-lock "$root/usr/bin/omarchy-update" || { reset_error "Factory updater lacks the maintenance-lock interface"; return 1; }
  grep -q -- --first-install "$root/usr/bin/omarchy-provision-user" || { reset_error "Factory baseline predates required user provisioning interface"; return 1; }
}
reset_closure_install() {
  local source=$1 root=$2 manifest=$3 file destination
  (umask 077; : >"$manifest") || return $?
  while IFS= read -r file; do
    destination="$root/usr/share/omarchy/$file"
    reset_closure_destination "$root" "usr/share/omarchy/$file" || return $?
    install -Dm644 "$source/$file" "$destination" || return $?
    if [[ $file == bin/* ]]; then
      chmod 755 "$destination" || return $?
      # The old package may use either a real /usr/bin file or a share alias.
      # Replace both locations with the exact current closure deliberately.
      reset_closure_destination "$root" "usr/bin/${file#bin/}" || return $?
      install -Dm755 "$source/$file" "$root/usr/bin/${file#bin/}" || return $?
      sha256sum "$source/$file" | awk -v path="/usr/bin/${file#bin/}" '{print $1 "  " path}' >>"$manifest" || return $?
    fi
    sha256sum "$source/$file" | awk -v path="/usr/share/omarchy/$file" '{print $1 "  " path}' >>"$manifest" || return $?
  done < <(reset_closure_files)
  sync -f "$manifest"
}

reset_closure_destination() {
  local root=$1 relative=$2 part current=$1 remaining=${2%/*}
  reset_safe_path "$relative" || return 1
  while [[ -n $remaining ]]; do
    part=${remaining%%/*}
    if [[ $remaining == */* ]]; then remaining=${remaining#*/}; else remaining=; fi
    current="$current/$part"
    [[ ! -L $current && (! -e $current || -d $current) ]] || {
      reset_error "Historical closure has an unsafe parent: $current"; return 1;
    }
  done
  [[ ! -e $root/$relative || -f $root/$relative || -L $root/$relative ]] || return 1
  # Replace a package alias itself, never follow it outside the selected root.
  if [[ -L $root/$relative ]]; then rm -- "$root/$relative" || return $?; fi
}

# The reset command owns this journal outside both roots. A boot failure or
# rename failure can therefore restore the original root and baseline without
# relying on whichever /var/lib tree is selected for the next boot.
reset_transaction_read() {
  local state=$1 extra
  [[ -d $state && ! -L $state && $(stat -c %u "$state") == 0 && $(stat -c %a "$state") == 700 ]] || return 1
  reset_private_file "$state/identities" || return 1
  read -r RESET_TXN_FS RESET_TXN_STAMP RESET_TXN_ROOT RESET_TXN_FACTORY RESET_TXN_NEXT RESET_TXN_CLEAN RESET_TXN_DEFAULT RESET_TXN_DEFAULT_PATH extra <"$state/identities"
  [[ -z $extra && $RESET_TXN_STAMP =~ ^[0-9]+$ ]] || return 1
  local identity
  for identity in "$RESET_TXN_FS" "$RESET_TXN_ROOT" "$RESET_TXN_FACTORY"; do [[ $identity =~ ^[a-fA-F0-9-]{36}$ ]] || return 1; done
  for identity in "$RESET_TXN_NEXT" "$RESET_TXN_CLEAN" "$RESET_TXN_DEFAULT"; do [[ $identity == - || $identity =~ ^[a-fA-F0-9-]{36}$ ]] || return 1; done
  if [[ $RESET_TXN_DEFAULT == - ]]; then
    [[ $RESET_TXN_DEFAULT_PATH == - ]] || return 1
  else
    reset_safe_path "$RESET_TXN_DEFAULT_PATH" || return 1
  fi
}
reset_transaction_record() {
  reset_state_write "$1/identities" "$RESET_TXN_FS $RESET_TXN_STAMP $RESET_TXN_ROOT $RESET_TXN_FACTORY $RESET_TXN_NEXT $RESET_TXN_CLEAN $RESET_TXN_DEFAULT $RESET_TXN_DEFAULT_PATH"
}
reset_transaction_rollback() {
  local top=$1 state=$2 current
  reset_transaction_read "$state" || return $?
  [[ $(findmnt -rn -T "$top" -o UUID) == "$RESET_TXN_FS" ]] || return 1
  # Recognize exact identities at both sides of each rename. Never overwrite
  # an occupied destination or clean an unknown interrupted staging object.
  if [[ -e $top/@ || -L $top/@ ]]; then
    current=$(reset_uuid "$top/@") || return $?
    if [[ $current == "$RESET_TXN_NEXT" ]]; then
      [[ ! -e $top/@omarchy-reset-next && ! -L $top/@omarchy-reset-next ]] || return 1
      mv -T "$top/@" "$top/@omarchy-reset-next" || return $?
    else [[ $current == "$RESET_TXN_ROOT" ]] || return 1; fi
  fi
  if [[ ! -e $top/@ && ! -L $top/@ ]]; then
    [[ $(reset_uuid "$top/@omarchy-old-$RESET_TXN_STAMP") == "$RESET_TXN_ROOT" ]] || return 1
    mv -T "$top/@omarchy-old-$RESET_TXN_STAMP" "$top/@" || return $?
  fi
  if [[ -e $top/@factory || -L $top/@factory ]]; then
    current=$(reset_uuid "$top/@factory") || return $?
    if [[ $current == "$RESET_TXN_CLEAN" ]]; then
      [[ ! -e $top/@omarchy-reset-factory && ! -L $top/@omarchy-reset-factory ]] || return 1
      mv -T "$top/@factory" "$top/@omarchy-reset-factory" || return $?
    else [[ $current == "$RESET_TXN_FACTORY" ]] || return 1; fi
  fi
  if [[ ! -e $top/@factory && ! -L $top/@factory ]]; then
    [[ $(reset_uuid "$top/@omarchy-old-factory-$RESET_TXN_STAMP") == "$RESET_TXN_FACTORY" ]] || return 1
    mv -T "$top/@omarchy-old-factory-$RESET_TXN_STAMP" "$top/@factory" || return $?
  fi
  reset_default_restore "$top" "$RESET_TXN_DEFAULT" "$RESET_TXN_DEFAULT_PATH" || return $?
  if [[ -e $state/boot/publication || -L $state/boot/publication ]]; then
    reset_private_file "$state/boot/publication" || return 1
    if [[ $(cat "$state/boot/publication") != rolled-back ]]; then
      reset_boot_rollback "$state/boot" provision || return $?
    fi
  fi
  if [[ -e $state/staged-luks || -L $state/staged-luks ]]; then
    if reset_private_file "$state/backend" && [[ $(cat "$state/backend") == grub ]]; then
      reset_staged_luks_rollback "$top" "$state" || return $?
    else
      reset_error "Limine reset key-slot intent retained for manual boot/key reconciliation: $state/staged-luks" || true
    fi
  fi
  [[ $(reset_uuid "$top/@") == "$RESET_TXN_ROOT" && $(reset_uuid "$top/@factory") == "$RESET_TXN_FACTORY" ]] || return 1
  reset_state_write "$state/phase" rolled-back || return $?
  sync -f "$top"
}

reset_cancel_journal() {
  local state=$1 expected=$2
  reset_private_file "$state/identities" || return 1
  [[ $(cat "$state/identities") == "$expected" && ! -e $state/phase && ! -L $state/phase && ! -e $state/services && ! -L $state/services ]] || return 1
  [[ ! -L $state/inventory && (! -e $state/inventory || -f $state/inventory) ]] || return 1
  rm -f -- "$state/identities" "$state/inventory" || return $?
  # Unknown additional state is preserved, never swept up on cancellation.
  rmdir "$state"
}

reset_staged_luks_rollback() {
  local top=$1 state=$2 uuid slot old_slots extra device slots previous key="$1/@omarchy-reset-next/var/lib/omarchy/provisioning/luks-key"
  reset_private_file "$state/staged-luks" || return 1
  read -r uuid slot old_slots extra <"$state/staged-luks"
  [[ $uuid =~ ^[a-fA-F0-9-]{36}$ && $slot =~ ^[0-9]+$ && $slot -le 31 && $old_slots =~ ^[0-9]+(,[0-9]+)*$ && -z $extra ]] || return 1
  device="/dev/disk/by-uuid/$uuid"
  [[ -b $device && $(cryptsetup luksUUID "$device") == "$uuid" ]] || return 1
  slots=$(owner_rekey_slots "$device") || return $?
  for previous in ${old_slots//,/ }; do grep -qx "$previous" <<<"$slots" || return 1; done
  if grep -qx "$slot" <<<"$slots"; then
    reset_private_file "$key" || return 1
    cryptsetup open --test-passphrase --key-slot "$slot" --key-file "$key" "$device" || return $?
    cryptsetup luksKillSlot -q --key-file "$key" "$device" "$slot" || return $?
  fi
  reset_state_write "$state/staged-luks-result" rolled-back
}

reset_limine_record() {
  local state=$1 entry=$2 previous=""
  if [[ -e $state/limine-services || -L $state/limine-services ]]; then
    reset_private_file "$state/limine-services" || return 1
    previous=$(cat "$state/limine-services") || return $?
  fi
  reset_state_write "$state/limine-services" "${previous:+$previous$'\n'}$entry"
}
reset_limine_quiesce() {
  local state=$1 unit loaded enabled active deadline=$((SECONDS + 30)) service_found=0
  for unit in limine-snapper-sync.service limine-snapper-sync.path; do
    loaded=$(systemctl show "$unit" --property=LoadState --value) || return $?
    [[ $loaded != not-found ]] || continue
    [[ $unit != limine-snapper-sync.service ]] || service_found=1
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    active=$(systemctl show "$unit" --property=ActiveState --value) || return $?
    if [[ $unit == *.path && $active == active ]]; then
      [[ $enabled != masked* ]] || { reset_error 'Preserve the administrator masked-but-active Limine path'; return 1; }
      reset_limine_record "$state" "path $unit" || return $?
      systemctl stop "$unit" || return $?
    fi
    if [[ $enabled != masked* ]]; then
      reset_limine_record "$state" "mask $unit" || return $?
      systemctl mask --runtime "$unit" || return $?
    fi
  done
  (( service_found )) || return 0
  while true; do
    active=$(systemctl show limine-snapper-sync.service --property=ActiveState --value) || return $?
    [[ $active == inactive || $active == failed || -z $active ]] && break
    (( SECONDS < deadline )) || { reset_error 'Finish the active Limine writer before reset'; return 1; }
    sleep 0.2
  done
}
reset_limine_resume() {
  local state=$1 kind unit extra
  [[ -e $state/limine-services || -L $state/limine-services ]] || return 0
  reset_private_file "$state/limine-services" || return 1
  local -a masks=() paths=()
  local -A seen=()
  while read -r kind unit extra; do
    [[ -z $extra && ! ${seen["$kind $unit"]+yes} ]] || return 1
    case "$kind $unit" in
      'mask limine-snapper-sync.service'|'mask limine-snapper-sync.path') masks+=("$unit") ;;
      'path limine-snapper-sync.path') paths+=("$unit") ;;
      *) return 1 ;;
    esac
    seen["$kind $unit"]=1
  done <"$state/limine-services"
  for unit in "${masks[@]}"; do systemctl unmask --runtime "$unit" || return $?; done
  for unit in "${paths[@]}"; do systemctl start "$unit" || return $?; done
  rm -- "$state/limine-services"
}
