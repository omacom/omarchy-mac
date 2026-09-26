# Sourced by omarchy-mac-migrate: the mx-mac adapter.
#
# An mx-mac Mac runs the omarchy-mx-mac fork: the omarchy-dev and
# omarchy-settings-dev runtime pair with the rest of the fork's bundle, which
# omarchy-update-asahi-bundle installs from signed release assets with
# pacman -U, the fork's own [omarchy] release repository, and the Aurora kernel
# from [omarchy-aurora]. omarchy-update-asahi-repository and
# omarchy-update-aurora-repository keep those two sections on the fork's
# latest releases by rewriting pacman.conf. One transaction swaps the pair for
# omarchy and omarchy-settings, which conflict with it, and moves every fork
# build an official repository carries to that build. The switch drops both
# fork sections and the fork's keys. The updaters leave with omarchy-dev, and
# retire moves the state they read into the backup, so nothing can point the
# Mac back at a fork release. Encryption, snapshots and Limine stay the
# engine's: nothing here touches them.
# shellcheck disable=SC2154 # the engine defines the shared state

retired_repos+=(omarchy-aurora)
# The fork's release key, which signs the bundle's release pointers.
retired_keys+=(5983B1CA32CB778F4D74D24ECFF35022CA5B5959)

# What omarchy-update-asahi-bundle installs, so no repository lists it.
mx_mac_bundle="omarchy-dev omarchy-settings-dev omarchy-keyring omarchy-nvim quickshell-git ttf-jetbrains-mono-nerd-basic"
# The Mac packages every mx-mac Mac takes from the target when it carries them.
mx_mac_targets="omarchy omarchy-settings omarchy-mac omarchy-mac-boot linux-aurora linux-aurora-headers m1n1-aurora uboot-asahi limine-mkinitcpio-hook"
# What the target's packages replace, as on a tester.
mx_mac_replaced="linux-asahi linux-asahi-headers m1n1 omarchy-apple-boot omarchy-first-boot omarchy-settings-asahi"
# The records the bundle and channel updaters keep in /var/lib/omarchy.
mx_mac_state="asahi-quattro-release asahi-quattro-release.pending asahi-package-repository aurora-target.descriptor apple-silicon-channel apple-silicon-aurora-lane"

# The official name of a fork build. The official package conflicts with the
# fork one it replaces, so naming it removes the fork build in the same
# transaction.
mx_mac_counterpart() {
  case $1 in
    omarchy-dev) echo omarchy ;;
    omarchy-settings-dev) echo omarchy-settings ;;
    quickshell-git) echo quickshell ;;
    mise | dotnet-host | dotnet-runtime) echo "$1-bin" ;;
    *) echo "$1" ;;
  esac
}

# mx_mac_preflight INSTALLED LUKS: prints the states this adapter refuses.
mx_mac_preflight() {
  if [[ " $target_packages " != *" omarchy "* || " $target_packages " != *" omarchy-settings "* ]]; then
    echo "the target has no omarchy and omarchy-settings to replace omarchy-dev and omarchy-settings-dev"
  fi
}

# mx_mac_plan INSTALLED WORK: prints the transaction's targets, one per line,
# and writes WORK/allowed-removals, WORK/removals and WORK/kept. WORK/db holds
# the target's synced databases; the live ones are still the fork's.
#
# - A fork build is a bundle package, or a package installed at the exact
#   version the fork's [omarchy] or [omarchy-aurora] lists.
# - The target's packages are named as <target repository>/<name>, so a higher
#   installed version is replaced: the Mac packages always, kernel headers only
#   where headers are installed, and every other one where it is installed or
#   replaces a fork build.
# - Every other fork build is named when an official repository carries it,
#   by its own name or else by its official counterpart's, so it moves to the
#   official build even when that is older. One nothing official carries stays
#   installed and is listed in WORK/kept.
# - The fork builds whose official counterpart has another name are removed:
#   by the counterpart's conflict where it has one, else by name after the
#   install (a versioned conflict, such as dotnet-runtime-bin's, can miss the
#   fork's build). The transaction may also remove what the target's packages
#   replace.
mx_mac_plan() {
  local installed=$1 work=$2 name version counterpart repo official=$2/official fork=$2/fork present=$2/present named=$2/named
  LC_ALL=C pacman --config "$work/transaction.conf" --dbpath "$work/db" -Sl 2>/dev/null |
    awk -v candidate="$candidate_repo" '$1 != candidate { print $2 }' | LC_ALL=C sort -u >"$official"
  {
    for name in $mx_mac_bundle; do
      version=$(installed_version "$name" "$installed")
      [[ -z $version ]] || printf '%s %s\n' "$name" "$version"
    done
    for repo in omarchy omarchy-aurora; do
      [[ -f $pacman_db/sync/$repo.db ]] || continue
      LC_ALL=C pacman --config "$pacman_conf" --dbpath "$pacman_db" -Sl "$repo" 2>/dev/null |
        while read -r _ name version _; do
          [[ $(installed_version "$name" "$installed") != "$version" ]] || printf '%s %s\n' "$name" "$version"
        done
    done
  } | LC_ALL=C sort -u >"$fork"
  {
    awk '{ print $1 }' "$installed"
    while read -r name _; do
      mx_mac_counterpart "$name"
    done <"$fork"
  } | LC_ALL=C sort -u >"$present"

  : >"$named"
  for name in $target_packages; do
    if [[ $name == *-headers ]]; then
      grep -Eq '^linux-(asahi|aurora)-headers ' "$installed" || continue
    fi
    if [[ " $mx_mac_targets " == *" $name "* ]] || grep -Fxq "$name" "$present"; then
      printf '%s/%s\n' "$target_repo" "$name"
      printf '%s\n' "$name" >>"$named"
    fi
  done

  : >"$work/kept"
  : >"$work/allowed-removals"
  : >"$work/removals"
  while read -r name version; do
    counterpart=$(mx_mac_counterpart "$name")
    if grep -Fxq "$name" "$named"; then
      continue
    elif grep -Fxq "$counterpart" "$named"; then
      :
    elif grep -Fxq "$name" "$official"; then
      printf '%s\n' "$name"
      continue
    elif grep -Fxq "$counterpart" "$official"; then
      printf '%s\n' "$counterpart"
    else
      printf '%s %s\n' "$name" "$version" >>"$work/kept"
      continue
    fi
    printf '%s\n' "$name" | tee -a "$work/allowed-removals" >>"$work/removals"
  done <"$fork"
  for name in $mx_mac_replaced; do
    [[ -z $(installed_version "$name" "$installed") ]] || printf '%s\n' "$name" >>"$work/allowed-removals"
  done
}

# The updaters left with omarchy-dev; what they read is kept with the backup,
# where no updater or check looks for it.
mx_mac_retire() {
  local name moved=$backup/mx-mac-state
  for name in $mx_mac_state; do
    [[ -e $R/var/lib/omarchy/$name || -L $R/var/lib/omarchy/$name ]] || continue
    install -d -m 700 "$moved" && mv -f "$R/var/lib/omarchy/$name" "$moved/$name" || return 1
    interrupt_for_test mid mx-mac-retire
  done
  if [[ -d $moved ]]; then
    sync "$moved" "$R/var/lib/omarchy" || return 1
  fi
  if [[ -s $plan/kept ]]; then
    say "Kept, with no official build: $(awk '{ print $1 }' "$plan/kept" | xargs)"
  fi
}
