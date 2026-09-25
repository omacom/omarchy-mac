# Sourced by omarchy-mac-migrate: the legacy omarchy-mac adapter, step one
# (trust and packages). Its boot switch cases are ticket 45's.
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
# - before the transaction, the checkout is unwired (restored if pacman fails)
#   and the files no package owns that the new packages bring are backed up
#   and overwritten; a file another package keeps owning stops the migration.
# Encrypted legacy Macs unlock through busybox encrypt, and the engine refuses
# them until their boot switch; nothing here changes the checkout itself.
# shellcheck disable=SC2154 # the engine and the tester adapter define the shared state

# Built beside the pair by the checkout's build-packages.sh.
legacy_built="omarchy-keyring ttf-jetbrains-mono-nerd-basic"
legacy_keyring=omarchy-mac-keyring
legacy_channel_stages=$R/var/cache/omarchy/channels

# The checkout /usr/share/omarchy links to, or nothing on a packaged install.
legacy_checkout() {
  [[ ! -L $R/usr/share/omarchy ]] || readlink "$R/usr/share/omarchy"
}

# legacy_preflight INSTALLED LUKS: prints the states this adapter refuses.
legacy_preflight() {
  local installed=$1 stage fpr
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
}

# legacy_plan INSTALLED WORK: the tester plan, plus the checkout's own builds
# where an official repository carries them, and the fork keyring's removal.
legacy_plan() {
  local installed=$1 work=$2 targets name
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
}

# legacy_conflicts BEFORE AFTER: the files the packages AFTER adds or replaces
# (the targets and every new name) would write over. A path no package owns is
# printed: the transaction may overwrite it. A path a package keeps owning
# stops the migration, before anything is written. Paths the checkout's
# links reach are left out: the links go first.
legacy_conflicts() {
  local before=$1 after=$2 checkout names=() name version dir archive path paths=$state/conflicts
  checkout=$(<"$plan/adapter/checkout")
  while read -r name version; do
    if [[ -z $(installed_version "$name" "$before") ]] || sed 's|^.*/||' "$plan/targets" | grep -Fxq "$name"; then
      names+=("$name $version")
    fi
  done < <(comm -13 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after"))
  : >"$paths.new"
  for name in "${names[@]}"; do
    version=${name#* }
    name=${name% *}
    archive=""
    for dir in "$cache/pkg" "$pacman_cache" "$cache/candidate"; do
      for path in "$dir/$name-$version"-*.pkg.tar.*; do
        [[ -f $path && $path != *.sig ]] && archive=$path
      done
    done
    [[ -n $archive ]] || die "the archive of $name $version is not in the cache"
    LC_ALL=C pacman -Qlpq "$archive" >>"$paths.new" || die "cannot list the files of $archive"
  done
  LC_ALL=C sort -u "$paths.new" | while IFS= read -r path; do
    [[ $path == */ ]] && continue
    if [[ -n $checkout ]]; then
      [[ $path != /usr/share/omarchy/* ]] || continue
      [[ ! ( $path == /usr/bin/omarchy-* && -L $R$path && $(readlink "$R$path") == "$checkout"/* ) ]] || continue
    fi
    [[ -e $R$path || -L $R$path ]] && [[ ! -d $R$path || -L $R$path ]] && printf '%s\n' "$path"
  done >"$paths" || true
  rm -f "$paths.new"
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

# Checked once the rehearsal knows what the transaction installs.
legacy_prefetch() {
  legacy_conflicts "$cache/start" "$cache/expected" >/dev/null
}

# Keeps the first copy of a file the conversion replaces or removes.
legacy_keep() {
  local path=$1 kept=$backup/converted/files$1
  [[ -e $kept || -L $kept ]] && return 0
  install -d -m 700 "$(dirname "$kept")" && cp -a "$R$path" "$kept"
}

# Unwires the checkout and lists the unowned files the transaction replaces,
# each backed up first. Every run repeats it from the start.
legacy_prepare() {
  local checkout link target converted=$backup/converted
  checkout=$(<"$plan/adapter/checkout")
  install -d -m 700 "$converted"
  touch "$converted/links"
  if [[ -n $checkout ]]; then
    for link in "$R"/usr/bin/omarchy-* "$R/usr/share/omarchy"; do
      [[ -L $link ]] || continue
      target=$(readlink "$link")
      [[ $target == "$checkout" || $target == "$checkout"/* ]] || continue
      grep -Fxq "${link#"$R"}"$'\t'"$target" "$converted/links" ||
        printf '%s\t%s\n' "${link#"$R"}" "$target" >>"$converted/links"
      rm -f "$link"
      interrupt_for_test mid unwire
    done
  fi
  if [[ -f $R/etc/omarchy.conf ]] && ! grep -Fxq 'export OMARCHY_PATH="/usr/share/omarchy"' "$R/etc/omarchy.conf"; then
    legacy_keep /etc/omarchy.conf || return 1
    printf 'export OMARCHY_PATH="/usr/share/omarchy"\n' | durable_write "$R/etc/omarchy.conf" 644 || return 1
  fi
  if [[ -e $R/etc/sudoers.d/omarchy-dev-path ]]; then
    legacy_keep /etc/sudoers.d/omarchy-dev-path && rm -f "$R/etc/sudoers.d/omarchy-dev-path" || return 1
  fi
  legacy_conflicts "$state/installed.now" "$expected" >"$state/overwrite.new" || return 1
  while IFS= read -r target; do
    legacy_keep "$target" || return 1
  done <"$state/overwrite.new"
  sync "$converted"
  mv "$state/overwrite.new" "$state/overwrite"
  interrupt_for_test mid convert
}

# pacman failed: the links it did not replace come back, so the checkout keeps
# running until the transaction is run again.
legacy_restore() {
  local path target
  [[ -f $backup/converted/links ]] || return 0
  while IFS=$'\t' read -r path target; do
    [[ -e $R$path || -L $R$path ]] || ln -s "$target" "$R$path"
  done <"$backup/converted/links"
}

# The fork's channel machinery goes with its repository; an unencrypted root
# loses the autologin the fork's boot lock left, as quattro's own migration
# does. The checkout stays where it is, unused.
legacy_retire() {
  local checkout
  tester_retire
  rm -rf "$legacy_channel_stages"/transaction.*
  [[ -n $(<"$plan/luks") ]] || rm -f "$R/etc/sddm.conf.d/autologin.conf"
  checkout=$(<"$plan/adapter/checkout")
  if [[ -n $checkout ]]; then
    say "Omarchy now runs from its packages. The checkout at $checkout is no longer used; keep or remove it."
  fi
}
