# Sourced by omarchy-mac-migrate: the legacy omarchy-mac adapter: trust and
# packages, then the boot switch.
#
# A legacy Mac runs omarchy-mac's quattro fork in one of three layouts:
# - a 3.x checkout upgraded to Quattro (omarchy-upgrade-to-quattro-mac): no
#   omarchy package; /usr/share/omarchy links to ~/.local/share/omarchy,
#   /usr/bin/omarchy-* link into it and /etc/omarchy.conf points OMARCHY_PATH
#   at it, and the setup it ran left the files a package would own unowned;
# - a guided install (omarchy-mac-setup, install.sh): omarchy and
#   omarchy-settings, and the keyrings and font beside them, built from that
#   checkout and installed with pacman -U;
# - a channel install: the pair from an [omarchy-aarch64] lane.
# All of them trust [omarchy-aarch64] (Optional TrustAll, TrustedOnly from rc5
# on) and, since rc4, omarchy-mac-keyring, whose populate trusts the fork key
# FBD6874D…. The engine drops the repository and the key; this adapter plans
# the packages as the tester adapter does, and adds:
# - the packages the checkout built move to their official builds;
# - omarchy-mac-keyring is removed once nothing needs it, so no populate
#   trusts the fork key again;
# - before the transaction, the files no package owns that the new packages
#   bring are backed up and overwritten (pacman keeps a changed configuration
#   file and writes .pacnew), then the checkout is unwired, and all of it is
#   restored if pacman fails; a file another package keeps owning stops the
#   migration.
# Nothing here changes the checkout itself.
#
# The boot switch is the loader step's stage, run while GRUB still boots the
# Mac and undone when it or the Limine activation fails:
# - an ESP mounted at /boot (the quattro guided installer's encrypted layout,
#   omarchy-system-boot-to-esp) moves to /boot/efi, where Limine and its UKI
#   live; /boot becomes the root filesystem's again and gets the kernel and
#   its initramfs. GRUB's own files stay on the ESP, untouched, so the GRUB
#   chain boots as before until Limine takes U-Boot's slot;
# - a root unlocked by busybox encrypt and cryptdevice= keeps its LUKS header,
#   keyslots and passphrase and moves to the converged unlock: crypttab's root
#   and rd.luks.name= on the kernel line, and the systemd initramfs the Apple
#   boot package composes (sd-encrypt), which is checked before Limine is.
#   The package transaction before it still builds the busybox image GRUB
#   boots: preflight requires encrypt in mkinitcpio.conf's own HOOKS, which
#   keeps the HOOKS baseline off such a line. An unencrypted Mac keeps its
#   HOOKS and stays unencrypted.
# Retire removes the kernels and GRUB the moved ESP still carries.
# shellcheck disable=SC2154 # the engine and the tester adapter define the shared state

# Built beside the pair by the checkout's build-packages.sh.
legacy_built="omarchy-keyring ttf-jetbrains-mono-nerd-basic"
legacy_keyring=omarchy-mac-keyring
# The kernel the boot switch puts on the root's /boot.
legacy_kernel=linux-aurora
legacy_channel_stages=$R/var/cache/omarchy/channels
legacy_packaged_path='export OMARCHY_PATH="/usr/share/omarchy"'

# The checkout /usr/share/omarchy links to, or nothing on a packaged install.
legacy_checkout() {
  [[ ! -L $R/usr/share/omarchy ]] || readlink "$R/usr/share/omarchy"
}

# legacy_preflight INSTALLED LUKS HOOKS: prints the states this adapter refuses.
legacy_preflight() {
  local installed=$1 luks=${2:-} hooks=${3:-} stage fpr esp_mount
  if ! grep -Eq '^omarchy ' "$installed" && [[ ! -L $R/usr/share/omarchy ]]; then
    echo "Omarchy is neither a package nor a Quattro checkout here: upgrade the 3.x install with omarchy-upgrade-to-quattro-mac first"
  fi
  if grep -Eq '^[[:space:]]*IgnorePkg[[:space:]]*=.*#[[:space:]]*omarchy-install-pair' "$pacman_conf"; then
    echo "an interrupted omarchy-mac channel install left its package pin in $pacman_conf (# omarchy-install-pair); finish that install or remove the line"
  fi
  for stage in "$legacy_channel_stages"/transaction.*; do
    [[ ! -e $stage/restore-sync ]] ||
      echo "an interrupted omarchy-mac channel switch still owes its sync databases a restore (${stage#"$R"}); finish it first"
  done
  if [[ -f $R/usr/share/pacman/keyrings/omarchy-mac-trusted ]]; then
    while IFS=: read -r fpr _; do
      [[ -z $fpr || " ${retired_keys[*]} " == *" $fpr "* ]] ||
        echo "omarchy-mac-keyring trusts $fpr, a key this migration does not remove"
    done <"$R/usr/share/pacman/keyrings/omarchy-mac-trusted"
  fi
  esp_mount=$(omarchy-mac-esp 2>/dev/null) || esp_mount=""
  if [[ $esp_mount == "/boot" ]]; then
    legacy_fstab_esp >/dev/null ||
      echo "the ESP is mounted at /boot, but /etc/fstab has no single vfat line mounting it there to move to /boot/efi"
    ! findmnt --mountpoint "$R/boot/efi" >/dev/null 2>&1 ||
      echo "the ESP is mounted at /boot and something else at /boot/efi, where the ESP moves"
  fi
  if [[ -n $luks && " $hooks " == *" encrypt "* ]]; then
    legacy_busybox_problems "$luks" "$esp_mount"
  fi
}

# The device of the one vfat line in fstab mounting the ESP at /boot.
legacy_fstab_esp() {
  awk '$1 !~ /^#/ && $2 == "/boot" && $3 == "vfat" { device = $1; found++ } END { if (found != 1) exit 1; print device }' "$R/etc/fstab" 2>/dev/null
}

# fstab (stdin) with the ESP's /boot line mounting it at /boot/efi instead.
legacy_esp_fstab() {
  awk '$1 !~ /^#/ && NF >= 4 && $2 == "/boot" && $3 == "vfat" { $2 = "/boot/efi" } { print }'
}

# GRUB's value of a defaults variable, as omarchy-mac-limine-cmdline reads it.
legacy_grub_value() {
  sed -n "s/^$1=//p" "$R/etc/default/grub" 2>/dev/null | tail -n 1 | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}

# The busybox encrypt words GRUB's defaults pass, one per line.
legacy_crypt_words() {
  local words=() word
  read -ra words <<<"$(legacy_grub_value GRUB_CMDLINE_LINUX) $(legacy_grub_value GRUB_CMDLINE_LINUX_DEFAULT)"
  for word in "${words[@]}"; do
    [[ $word != cryptdevice=* && $word != cryptkey=* ]] || printf '%s\n' "$word"
  done
}

# A root busybox encrypt unlocks moves only from the layout the quattro guided
# installer made: one cryptdevice=UUID=<this LUKS partition>:root, the kernels
# on the ESP at /boot, encrypt in mkinitcpio.conf's own HOOKS (which keeps the
# transaction's image unlocking until the switch) and no other root in crypttab.
legacy_busybox_problems() {
  local luks=$1 esp_mount=$2 uuid words=() source spec
  uuid=$(cryptsetup luksUUID "$luks" 2>/dev/null) || uuid=""
  mapfile -t words < <(legacy_crypt_words)
  if (( ${#words[@]} != 1 )) || [[ ! ${words[0]} =~ ^cryptdevice=UUID=([0-9A-Fa-f-]+):root(:allow-discards)?$ ]] ||
    [[ -z $uuid || ${BASH_REMATCH[1],,} != "${uuid,,}" ]]; then
    echo "the root unlocks through busybox encrypt, but GRUB's defaults do not pass the one cryptdevice=UUID=${uuid:-<its LUKS UUID>}:root[:allow-discards] this migration moves (found: ${words[*]:-none})"
  fi
  source=$(findmnt -no SOURCE "$R/" 2>/dev/null) || source=""
  [[ ${source%%[*} == "/dev/mapper/root" ]] || echo "the encrypted root is not mounted from /dev/mapper/root, the mapping cryptdevice= opens"
  grep -Eq '^[[:space:]]*HOOKS=\(([^)#]*[[:space:]])?encrypt([[:space:]][^)#]*)?\)' "$R/etc/mkinitcpio.conf" 2>/dev/null ||
    echo "busybox encrypt is not in /etc/mkinitcpio.conf's own HOOKS, so the package transaction could drop the unlock GRUB boots with; add it there first"
  [[ $esp_mount == "/boot" ]] ||
    echo "the encrypted root's kernels are not on the ESP mounted at /boot (the quattro guided installer's layout); the ESP is at ${esp_mount:-no mountpoint}"
  spec=$(awk '$1 == "root" { print $2; exit }' "$R/etc/crypttab" 2>/dev/null)
  [[ -z $spec || ${spec,,} == "uuid=${uuid,,}" ]] || echo "/etc/crypttab names another root ($spec)"
}

# legacy_plan INSTALLED WORK LUKS HOOKS: the tester plan, plus the checkout's
# own builds where an official repository carries them, and the fork keyring's
# removal. The boot switch's unlock is recorded: "busybox UUID DISCARD" for a
# root busybox encrypt unlocks, nothing otherwise.
legacy_plan() {
  local installed=$1 work=$2 luks=${3:-} hooks=${4:-} targets name word uuid
  targets=$(tester_plan "$installed" "$work") || return 1
  printf '%s\n' "$targets"
  for name in $legacy_built; do
    [[ -n $(installed_version "$name" "$installed") ]] && grep -Fxq "$name" "$work/official" || continue
    sed 's|^.*/||' <<<"$targets" | grep -Fxq "$name" || printf '%s\n' "$name"
  done
  : >"$work/removals"
  if [[ -n $(installed_version "$legacy_keyring" "$installed") ]]; then
    printf '%s\n' "$legacy_keyring" | tee -a "$work/allowed-removals" >"$work/removals"
    sed -i "/^$legacy_keyring /d" "$work/kept"
  fi
  install -d -m 755 "$work/adapter"
  legacy_checkout >"$work/adapter/checkout"
  : >"$work/adapter/unlock"
  if [[ -n $luks && " $hooks " == *" encrypt "* ]]; then
    word=$(legacy_crypt_words)
    uuid=${word#cryptdevice=UUID=}
    printf 'busybox %s %s\n' "${uuid%%:*}" "$([[ $word == *:allow-discards ]] && echo 1 || echo 0)" >"$work/adapter/unlock"
  fi
}

# The archives of what AFTER adds or replaces: the targets and every new name.
legacy_archives() {
  local before=$1 after=$2 name version dir archive path
  while read -r name version; do
    [[ -z $(installed_version "$name" "$before") ]] || sed 's|^.*/||' "$plan/targets" | grep -Fxq "$name" || continue
    archive=""
    for dir in "$pacman_cache" "$cache/candidate" "$cache/pkg"; do
      for path in "$dir/$name-$version"-*.pkg.tar.*; do
        [[ -f $path && $path != *.sig ]] && archive=$path
      done
    done
    [[ -n $archive ]] || die "the archive of $name $version is not in the cache"
    printf '%s\n' "$archive"
  done < <(comm -13 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after"))
}

# legacy_conflicts BEFORE AFTER: the files those archives would write over. A
# path no package owns is printed: the transaction may overwrite it. A path a
# package keeps owning stops the migration, before anything is written. While
# the checkout is still linked in, the paths its links reach are left out:
# the links go before pacman runs.
legacy_conflicts() {
  local before=$1 after=$2 checkout archive path name paths=$state/conflicts
  checkout=$(<"$plan/adapter/checkout")
  : >"$paths.new"
  legacy_archives "$before" "$after" >"$paths.archives"
  while read -r archive; do
    LC_ALL=C pacman -Qlpq "$archive" >>"$paths.new" || die "cannot list the files of $archive"
  done <"$paths.archives"
  LC_ALL=C sort -u "$paths.new" | while IFS= read -r path; do
    [[ $path == */ ]] && continue
    if [[ -n $checkout ]]; then
      [[ ! ( $path == /usr/share/omarchy/* && -L $R/usr/share/omarchy ) ]] || continue
      [[ ! ( $path == /usr/bin/omarchy-* && -L $R$path && $(readlink "$R$path") == "$checkout"/* ) ]] || continue
    fi
    [[ -e $R$path || -L $R$path ]] && [[ ! -d $R$path || -L $R$path ]] && printf '%s\n' "$path"
  done >"$paths" || true
  rm -f "$paths.new" "$paths.archives"
  [[ -s $paths ]] || return 0
  LC_ALL=C pacman --config "$pacman_conf" --dbpath "$pacman_db" -Ql |
    awk 'NR == FNR { wanted[$0]; next } { owner = $1; sub(/^[^ ]+ /, "") } $0 in wanted { print $0 "\t" owner }' "$paths" - >"$paths.owned" ||
    die "cannot read which packages own the conflicting files"
  while IFS= read -r path; do
    name=$(awk -F'\t' -v path="$path" '$1 == path { print $2; exit }' "$paths.owned")
    if [[ -z $name ]]; then
      [[ $path != *,* ]] || die "the new packages bring $path, which no package owns, and pacman cannot be told to overwrite a path with a comma; move it away first"
      printf '%s\n' "$path"
    elif [[ $(installed_version "$name" "$before") == "$(installed_version "$name" "$after")" ]]; then
      die "the new packages would overwrite $path, which $name owns and keeps; nothing was changed"
    fi
  done <"$paths"
  rm -f "$paths" "$paths.owned"
}

# Once the rehearsal knows what the transaction installs: its conflicts are
# checked, and the archives the check reads are linked into the migration's own
# cache, so pruning pacman's cache cannot strand a resumed transaction.
legacy_prefetch() {
  local archive
  legacy_conflicts "$cache/start" "$cache/expected" >/dev/null
  legacy_archives "$cache/start" "$cache/expected" >"$cache/archives"
  while read -r archive; do
    [[ $archive != "$cache"/* ]] || continue
    ln -f "$archive" "$cache/pkg/" 2>/dev/null || cp -p "$archive" "$cache/pkg/" || die "cannot keep $archive for the transaction"
  done <"$cache/archives"
}

# Keeps the first copy of a file the conversion replaces or removes.
legacy_keep() {
  local path=$1 kept=$backup/converted/files$1
  [[ -e $kept || -L $kept ]] && return 0
  install -d -m 700 "$(dirname "$kept")" && cp -a "$R$path" "$kept"
}

# Lists the unowned files the transaction replaces and backs each up, then
# unwires the checkout: nothing changes until everything that can fail on the
# way has passed. Every run repeats it from the start.
legacy_prepare() {
  local checkout link target converted=$backup/converted
  checkout=$(<"$plan/adapter/checkout")
  install -d -m 700 "$converted"
  touch "$converted/links"
  legacy_conflicts "$state/installed.now" "$expected" >"$state/overwrite.new"
  while IFS= read -r target; do
    legacy_keep "$target" || return 1
  done <"$state/overwrite.new"
  if [[ -f $R/etc/omarchy.conf ]] && ! grep -Fxq "$legacy_packaged_path" "$R/etc/omarchy.conf"; then
    legacy_keep /etc/omarchy.conf || return 1
  fi
  if [[ -e $R/etc/sudoers.d/omarchy-dev-path ]]; then
    legacy_keep /etc/sudoers.d/omarchy-dev-path || return 1
  fi
  sync "$converted"
  if [[ -n $checkout ]]; then
    for link in "$R"/usr/bin/omarchy-* "$R/usr/share/omarchy"; do
      [[ -L $link ]] || continue
      target=$(readlink "$link")
      [[ $target == "$checkout" || $target == "$checkout"/* ]] || continue
      grep -Fxq "${link#"$R"}"$'\t'"$target" "$converted/links" ||
        printf '%s\t%s\n' "${link#"$R"}" "$target" >>"$converted/links" || return 1
      rm -f "$link" || return 1
      interrupt_for_test mid unwire
    done
  fi
  if [[ -f $R/etc/omarchy.conf ]] && ! grep -Fxq "$legacy_packaged_path" "$R/etc/omarchy.conf"; then
    printf '%s\n' "$legacy_packaged_path" | durable_write "$R/etc/omarchy.conf" 644 || return 1
  fi
  rm -f "$R/etc/sudoers.d/omarchy-dev-path" || return 1
  mv "$state/overwrite.new" "$state/overwrite" || return 1
  interrupt_for_test mid convert
}

# The transaction could not run: the links pacman did not replace come back,
# and so do the checkout's OMARCHY_PATH and a dev link's sudo path, so the Mac
# runs as before until the transaction is run again.
legacy_restore() {
  local path target kept=$backup/converted/files
  if [[ -f $backup/converted/links ]]; then
    while IFS=$'\t' read -r path target; do
      [[ -e $R$path || -L $R$path ]] || ln -s "$target" "$R$path"
    done <"$backup/converted/links"
  fi
  if [[ -f $kept/etc/omarchy.conf ]] && grep -Fxq "$legacy_packaged_path" "$R/etc/omarchy.conf" 2>/dev/null; then
    cp -a "$kept/etc/omarchy.conf" "$R/etc/omarchy.conf"
  fi
  if [[ -f $kept/etc/sudoers.d/omarchy-dev-path && ! -e $R/etc/sudoers.d/omarchy-dev-path ]]; then
    cp -a "$kept/etc/sudoers.d/omarchy-dev-path" "$R/etc/sudoers.d/omarchy-dev-path"
  fi
  return 0
}

# --- The boot switch -----------------------------------------------------------

# Keeps the first copy of a file the boot switch changes, or a note that it did
# not exist, so the switch can be undone; written whole, never half.
legacy_stage_keep() {
  local path=$1 kept=$backup/boot-switch
  [[ -e $kept/files$path || -L $kept/files$path || -e $kept/absent$path ]] && return 0
  if [[ -e $R$path || -L $R$path ]]; then
    install -d -m 700 "$(dirname "$kept/files$path")" &&
      cp -a "$R$path" "$kept/files$path.new" && sync "$kept/files$path.new" && mv "$kept/files$path.new" "$kept/files$path"
  else
    install -d -m 700 "$(dirname "$kept/absent$path")" && : >"$kept/absent$path" && sync "$kept/absent$path"
  fi
}

# Puts back what legacy_stage_keep kept of PATH.
legacy_stage_restore() {
  local path=$1 kept=$backup/boot-switch
  if [[ -e $kept/absent$path ]]; then
    rm -f "$R$path"
  elif [[ -e $kept/files$path || -L $kept/files$path ]]; then
    cp -a "$kept/files$path" "$R$path.restore" && mv -f "$R$path.restore" "$R$path"
  fi
}

# The ESP moves from /boot to /boot/efi: fstab first, then the mounts. Each
# part is skipped once done, so a run cut short continues where it was.
legacy_move_esp() {
  local fstab=$R/etc/fstab
  if legacy_fstab_esp >/dev/null; then
    legacy_stage_keep /etc/fstab || return 1
    legacy_esp_fstab <"$fstab" | durable_write "$fstab" 644 || return 1
    systemctl daemon-reload >/dev/null 2>&1 || echo "systemctl daemon-reload failed; the mounts move anyway" >&2
  fi
  interrupt_for_test mid esp-fstab
  if [[ $(omarchy-mac-esp 2>/dev/null) == "/boot" ]]; then
    umount "$R/boot" || { echo "cannot unmount the ESP from /boot" >&2; return 1; }
  fi
  interrupt_for_test mid esp-unmounted
  if [[ $(omarchy-mac-esp 2>/dev/null) != "/boot/efi" ]]; then
    install -d -m 755 "$R/boot/efi" && mount "$R/boot/efi" || { echo "cannot mount the ESP at /boot/efi" >&2; return 1; }
  fi
  [[ $(omarchy-mac-esp 2>/dev/null) == "/boot/efi" ]] || { echo "the ESP is not mounted at /boot/efi after the move" >&2; return 1; }
}

# The ESP goes back to /boot. What the switch put on the root's /boot is
# removed only once no ESP covers it.
legacy_restore_esp() {
  local where
  where=$(omarchy-mac-esp 2>/dev/null) || where=""
  if [[ $where == "/boot/efi" ]]; then
    umount "$R/boot/efi" || { echo "cannot unmount the ESP from /boot/efi" >&2; return 1; }
  fi
  if ! findmnt --mountpoint "$R/boot" >/dev/null 2>&1; then
    rm -f "$R/boot/vmlinuz-$legacy_kernel" "$R/boot/initramfs-$legacy_kernel.img" "$R/boot/initramfs-$legacy_kernel-fallback.img"
    rmdir "$R/boot/efi" 2>/dev/null || true
  fi
  legacy_stage_restore /etc/fstab || return 1
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ $(omarchy-mac-esp 2>/dev/null) != "/boot" ]]; then
    mount "$R/boot" || { echo "cannot mount the ESP at /boot again" >&2; return 1; }
  fi
  [[ $(omarchy-mac-esp 2>/dev/null) == "/boot" ]] || { echo "the ESP is not back at /boot" >&2; return 1; }
}

# HOOKS lines (stdin) without busybox encrypt and asahi: the HOOKS baseline
# and the Apple boot package's drop-ins then compose the systemd image, the
# asahi hook back in its place with the firmware loader beside it. A HOOKS
# assignment that does not fit on one line cannot be edited: exit 2.
legacy_drop_hooks() {
  awk '
    /^[[:space:]]*HOOKS\+?=\(/ {
      if (!match($0, /\([^)]*\)/)) { bad = 1; print; next }
      head = substr($0, 1, RSTART); tail = substr($0, RSTART + RLENGTH - 1)
      n = split(substr($0, RSTART + 1, RLENGTH - 2), words, /[[:space:]]+/)
      kept = ""
      for (i = 1; i <= n; i++) if (words[i] != "" && words[i] != "encrypt" && words[i] != "asahi") kept = kept (kept == "" ? "" : " ") words[i]
      print head kept tail
      next
    }
    { print }
    END { exit bad ? 2 : 0 }
  '
}

# GRUB's defaults FILE with cryptdevice= gone and the root's rd.luks.name=
# (and rd.luks.options= for allow-discards) on the last GRUB_CMDLINE_LINUX,
# where the Apple encrypt flow keeps them and omarchy-mac-limine-cmdline reads
# them. Both variables are written double-quoted.
legacy_grub_unlock() {
  local file=$1 uuid=$2 discard=$3 want
  want="rd.luks.name=$uuid=root"
  (( ! discard )) || want+=" rd.luks.options=$uuid=discard"
  awk -v want="$want" '
    function strip(value,   n, i, words, out) {
      n = split(value, words, /[[:space:]]+/)
      out = ""
      for (i = 1; i <= n; i++)
        if (words[i] != "" && words[i] !~ /^(cryptdevice|rd\.luks\.name|rd\.luks\.options)=/) out = out (out == "" ? "" : " ") words[i]
      return out
    }
    NR == FNR { if ($0 ~ /^GRUB_CMDLINE_LINUX=/) last = FNR; next }
    /^GRUB_CMDLINE_LINUX(_DEFAULT)?=/ {
      key = $0; sub(/=.*/, "", key)
      value = $0; sub(/^[^=]*=/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
      value = strip(value)
      if (FNR == last) value = value (value == "" ? "" : " ") want
      print key "=\"" value "\""
      next
    }
    { print }
    END { if (!last) print "GRUB_CMDLINE_LINUX=\"" want "\"" }
  ' "$file" "$file"
}

# The root's unlock moves from busybox encrypt to sd-encrypt. Every file is
# kept first and written whole; running it again changes nothing.
legacy_switch_unlock() {
  local uuid=$1 discard=$2 options=luks file owned conf=$R/etc/mkinitcpio.conf grub=$R/etc/default/grub
  (( ! discard )) || options+=,discard
  legacy_stage_keep /etc/crypttab || return 1
  { [[ ! -f $R/etc/crypttab ]] || awk '$1 != "root"' "$R/etc/crypttab"; printf 'root UUID=%s none %s\n' "$uuid" "$options"; } |
    durable_write "$R/etc/crypttab" 644 || return 1
  legacy_stage_keep /etc/default/grub || return 1
  legacy_grub_unlock "$grub" "$uuid" "$discard" | durable_write "$grub" 644 || return 1
  interrupt_for_test mid unlock
  legacy_stage_keep /etc/mkinitcpio.conf || return 1
  legacy_drop_hooks <"$conf" >"$state/mkinitcpio.conf.new" ||
    { echo "cannot edit the HOOKS in /etc/mkinitcpio.conf (one HOOKS=(...) line each is expected)" >&2; return 1; }
  durable_write "$conf" 644 <"$state/mkinitcpio.conf.new" || return 1
  rm -f "$state/mkinitcpio.conf.new"
  # The fork's omarchy_hooks.conf sets the busybox line outright and sorts
  # after the Apple drop-ins. Where no package took it over, it goes too. Any
  # other drop-in is left alone; the check below names the HOOKS it gives.
  file=/etc/mkinitcpio.conf.d/omarchy_hooks.conf
  if [[ -f $R$file ]] && grep -Eq '^[[:space:]]*HOOKS=\(([^)#]*[[:space:]])?encrypt([[:space:]][^)#]*)?\)' "$R$file"; then
    owned=$(LC_ALL=C pacman --config "$pacman_conf" --dbpath "$pacman_db" -Qlq 2>/dev/null) ||
      { echo "cannot read which packages own $file" >&2; return 1; }
    if ! grep -Fxq "$file" <<<"$owned"; then
      legacy_stage_keep "$file" && rm -f "$R$file" || return 1
    fi
  fi
}

# The kernel on the root's /boot (as the kernel's own install hook copies it)
# and its initramfs. Never onto an ESP still mounted at /boot: GRUB boots that.
legacy_build_initramfs() {
  local release image target=$R/boot/vmlinuz-$legacy_kernel
  [[ $(omarchy-mac-esp 2>/dev/null) != "/boot" ]] || { echo "the ESP is still mounted at /boot" >&2; return 1; }
  release=$(kernel_release "$legacy_kernel") || { echo "$legacy_kernel has no module tree" >&2; return 1; }
  image=$R/usr/lib/modules/$release/vmlinuz
  if ! cmp -s "$image" "$target"; then
    install -m 644 "$image" "$target.new" && sync "$target.new" && mv -f "$target.new" "$target" ||
      { echo "cannot put $legacy_kernel on /boot" >&2; return 1; }
  fi
  interrupt_for_test mid initramfs
  mkinitcpio -p "$legacy_kernel" >"$state/mkinitcpio.log" 2>&1 ||
    { echo "mkinitcpio -p $legacy_kernel failed: $(tail -n 1 "$state/mkinitcpio.log")" >&2; return 1; }
}

# What the next boot unlocks with, checked before Limine is activated: the
# HOOKS, the image built from them, crypttab and the kernel line's source.
legacy_check_unlock() {
  local uuid=$1 hooks listing spec
  hooks=$(omarchy-mac-initramfs-hooks 2>/dev/null) || { echo "cannot read the initramfs HOOKS after the switch" >&2; return 1; }
  if [[ " $hooks " == *" encrypt "* || " $hooks " != *" systemd "* || " $hooks " != *" sd-encrypt "* || " $hooks " != *" asahi "* ]]; then
    echo "the initramfs HOOKS after the switch do not unlock the root through systemd (sd-encrypt, with asahi): $hooks" >&2
    return 1
  fi
  listing=$(lsinitcpio -l "$R/boot/initramfs-$legacy_kernel.img" 2>/dev/null) || { echo "/boot/initramfs-$legacy_kernel.img cannot be listed" >&2; return 1; }
  if ! grep -Eq '(^|/)usr/lib/systemd/system-generators/systemd-cryptsetup-generator$' <<<"$listing" ||
    ! grep -Eq '(^|/)usr/bin/systemd-cryptsetup$' <<<"$listing" || grep -Eq '(^|/)hooks/encrypt$' <<<"$listing"; then
    echo "/boot/initramfs-$legacy_kernel.img does not unlock the root through sd-encrypt" >&2
    return 1
  fi
  spec=$(awk '$1 == "root" { print $2; exit }' "$R/etc/crypttab" 2>/dev/null)
  [[ ${spec,,} == "uuid=${uuid,,}" ]] || { echo "/etc/crypttab does not name the root UUID=$uuid" >&2; return 1; }
  if [[ -n $(legacy_crypt_words) || " $(legacy_grub_value GRUB_CMDLINE_LINUX) " != *" rd.luks.name=$uuid=root "* ]]; then
    echo "GRUB's defaults, which Limine's kernel line comes from, do not unlock the root with rd.luks.name=$uuid=root alone" >&2
    return 1
  fi
}

# The loader step's stage, while GRUB still boots the Mac: the ESP off /boot,
# the unlock off busybox encrypt, then the kernel and initramfs Limine's UKI is
# built from. An unencrypted Mac with its ESP at /boot/efi has nothing to do.
legacy_stage() {
  local esp_mount unlock="" uuid="" discard=0
  esp_mount=$(plan_esp)
  [[ ! -s $plan/adapter/unlock ]] || read -r unlock uuid discard <"$plan/adapter/unlock"
  [[ $esp_mount == "/boot" || $unlock == "busybox" ]] || return 0
  if [[ $esp_mount == "/boot" ]]; then
    legacy_move_esp || return 1
  fi
  if [[ $unlock == "busybox" ]]; then
    legacy_switch_unlock "$uuid" "$discard" || return 1
  fi
  legacy_build_initramfs || return 1
  if [[ $unlock == "busybox" ]]; then
    legacy_check_unlock "$uuid" || return 1
  fi
}

# Undoes the stage in reverse: the unlock's files, then the ESP's mount. The
# busybox image GRUB boots stayed on the ESP throughout.
legacy_unstage() {
  local kept=$backup/boot-switch path
  [[ -d $kept ]] || return 0
  while IFS= read -r path; do
    [[ $path == "/etc/fstab" ]] || legacy_stage_restore "$path" || return 1
  done < <(cd "$kept" && find files absent \( -type f -o -type l \) ! -name '*.new' 2>/dev/null | sed -E 's#^(files|absent)##' | LC_ALL=C sort -u)
  if [[ $(plan_esp) == "/boot" ]]; then
    legacy_restore_esp || return 1
  fi
  echo "The boot switch was undone; GRUB boots this Mac as before." >&2
}

# The kernels, initramfs images and GRUB a moved ESP still carries at its top:
# Limine boots the UKI now, and the backup holds the ESP as it was.
legacy_retire_esp() {
  [[ $(plan_esp) == "/boot" ]] || return 0
  if [[ $(omarchy-mac-esp 2>/dev/null) != "/boot/efi" ]]; then
    say "The ESP is not mounted at /boot/efi; its old kernels and GRUB stay on it."
    return 0
  fi
  rm -f "$R"/boot/efi/vmlinuz-linux-* "$R"/boot/efi/initramfs-linux-*.img && rm -rf "$R/boot/efi/grub"
}

# The fork's channel machinery goes with its repository, and the copies of
# pacman.conf its tools left beside it that still trust unsigned packages move
# into the backup, so none is restored by mistake. The checkout stays where it
# is, unused. An autologin on an unencrypted root stays too: quattro retired
# the boot lock's own long ago, so one there now is an administrator's opt-in.
legacy_retire() {
  local checkout file
  tester_retire
  legacy_retire_esp || return 1
  rm -rf "$legacy_channel_stages"/transaction.*
  for file in "$R"/etc/pacman.conf.*; do
    [[ -f $file ]] && grep -Eq '^[[:space:]]*SigLevel[[:space:]]*=.*TrustAll' "$file" || continue
    legacy_keep "${file#"$R"}" && rm -f "$file" || return 1
  done
  checkout=$(<"$plan/adapter/checkout")
  if [[ -n $checkout ]]; then
    say "Omarchy now runs from its packages. The checkout at $checkout is no longer used; keep or remove it."
  fi
}
