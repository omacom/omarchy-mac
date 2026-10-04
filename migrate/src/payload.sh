# The boot tools preflight judges this Mac with: the boot check, the ESP
# finder and the HOOKS composer of the omarchy-mac-boot the transaction will
# install. A Mac on a fork has none it can trust, or older ones, so preflight
# takes them from that package's verified archive, unpacked where only root can
# write, and puts them first on its PATH. Nothing of the package is installed
# here and nothing in it runs but those read-only checks; after the
# transaction the installed package's own commands are used.
# shellcheck disable=SC2154

# The verified archive of NAME as the target resolves it, downloaded once into
# the work cache: a candidate set's from the verified copy of the set, a
# repository's by pacman, which checks its signature against the keyring copy
# that trusts the target's key (and no retired one). Prints its path, or why
# there is none.
fetch_archive() {
  local resolved=$1 wanted=$2 conf=$3 db=$4 name version file archive=""
  read -r name version < <(awk -v wanted="$wanted" '{ n = $1; sub(/^[^\/]*\//, "", n) } n == wanted { print $1, $2; exit }' "$resolved")
  [[ -n $name ]] || { echo "the target installs no $wanted"; return 1; }
  if [[ $name == "$candidate_repo/"* ]]; then
    file=$(jq -r --arg name "$wanted" --arg version "$version" '.packages[] | select(.name == $name and .version == $version) | .filename' "$target_set/manifest.json")
    [[ -n $file && -f $target_set/$file ]] && archive=$target_set/$file
  else
    install -d -m 755 "$work/archives"
    for file in "$work/archives/$wanted-$version"-*.pkg.tar.*; do
      [[ $file == *.sig || ! -f $file ]] || archive=$file
    done
    if [[ -z $archive ]]; then
      if ! pacman_run --config "$conf" --dbpath "$db" --cachedir "$work/archives" --logfile "$work/pacman.log" \
        -Swdd --noconfirm --ask 4 "$name" >"$work/download.log" 2>&1; then
        echo "cannot download and verify $wanted $version: $(tail -n 1 "$work/download.log")"
        return 1
      fi
      for file in "$work/archives/$wanted-$version"-*.pkg.tar.*; do
        [[ $file == *.sig || ! -f $file ]] || archive=$file
      done
    fi
  fi
  [[ -n $archive ]] || { echo "the archive of $wanted $version is missing"; return 1; }
  printf '%s\n' "$archive"
}

# Unpacks the verified archive of the resolved omarchy-mac-boot into DIR, where
# only root can write, and prints its version.
fetch_payload() {
  local resolved=$1 conf=$2 db=$3 dir=$4 archive version
  archive=$(fetch_archive "$resolved" omarchy-mac-boot "$conf" "$db") || { echo "$archive"; return 1; }
  version=$(awk '{ n = $1; sub(/^[^\/]*\//, "", n) } n == "omarchy-mac-boot" { print $2; exit }' "$resolved")
  rm -rf "$dir"
  install -d -m 700 "$dir"
  bsdtar -xpf "$archive" -C "$dir" 2>/dev/null || { echo "cannot unpack omarchy-mac-boot $version"; return 1; }
  [[ $(sed -n 's/^pkgname = //p' "$dir/.PKGINFO") == "omarchy-mac-boot" && $(sed -n 's/^pkgver = //p' "$dir/.PKGINFO") == "$version" ]] ||
    { echo "the archive is not omarchy-mac-boot $version"; return 1; }
  [[ -z $(find "$dir" ! -type l \( ! -uid "$EUID" -o -perm /022 \) -print -quit) ]] ||
    { echo "the unpacked omarchy-mac-boot is writable by others"; return 1; }
  printf '%s\n' "$version"
}

# The HOOKS the Mac's mkinitcpio configuration gives once the transaction has
# put the new settings and boot packages' drop-ins in place.
future_hooks() {
  local resolved=$1 conf=$2 db=$3 dir=$work/future-conf.d name archive pair
  rm -rf "$dir"
  install -d -m 700 "$dir"
  [[ ! -d $R/etc/mkinitcpio.conf.d ]] || cp -a "$R/etc/mkinitcpio.conf.d/." "$dir/" || { echo "cannot copy the drop-ins"; return 1; }
  pair=$(channel_pair "$target_channel")
  for name in "${pair#* }" omarchy-mac-boot; do
    archive=$(fetch_archive "$resolved" "$name" "$conf" "$db") || { echo "$archive"; return 1; }
    install -d -m 700 "$work/future-root-$name"
    # A package without drop-ins extracts nothing.
    bsdtar -xpf "$archive" -C "$work/future-root-$name" --include 'etc/mkinitcpio.conf.d/*' 2>/dev/null || true
    [[ ! -d $work/future-root-$name/etc/mkinitcpio.conf.d ]] || cp -a "$work/future-root-$name/etc/mkinitcpio.conf.d/." "$dir/"
  done
  OMARCHY_MKINITCPIO_CONF_DIR=$dir omarchy-mac-initramfs-hooks 2>/dev/null || { echo "the HOOKS composer failed"; return 1; }
}
