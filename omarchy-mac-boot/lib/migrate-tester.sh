# Sourced by omarchy-mac-migrate: the quattro-upstream tester adapter.
#
# A tester Mac runs omarchy, omarchy-settings and usually omarchy-mac built from
# quattro-upstream, from the unsigned collaboration repository
# ([omarchy-aarch64]), a candidate set or a pilot. Its same-name packages can be
# versioned above the target's (a candidate's pkgrel suffix, an rc runtime), so
# an upgrade would keep them: every one is named explicitly and replaced by the
# target's build. The Asahi kernel and m1n1 give way to their Aurora
# counterparts in the same transaction.
# shellcheck disable=SC2154 # the engine defines the shared state

# Packages the tester transaction may remove: what the target's packages
# replace (the Asahi kernel, its headers and m1n1) and the boot and settings
# packages omarchy-mac and omarchy-mac-boot superseded.
tester_replaced="linux-asahi linux-asahi-headers m1n1 omarchy-apple-boot omarchy-first-boot omarchy-settings-asahi"

# tester_plan INSTALLED WORK: prints the transaction's targets, one per line,
# and writes WORK/allowed-removals and WORK/kept. WORK/db holds the target's
# synced databases.
#
# - Each target package is named as <target repository>/<name>, so a higher
#   installed version is replaced. Kernel headers come only where headers are
#   installed.
# - A package installed from a retired repository, at the exact version that
#   repository lists, is named by itself when an official repository carries
#   it, so it moves to the official build even when that is older. One nothing
#   official carries stays installed and is listed in WORK/kept.
tester_plan() {
  local installed=$1 work=$2 name retired official
  for name in $target_packages; do
    if [[ $name == *-headers ]]; then
      grep -Eq '^linux-(asahi|aurora)-headers ' "$installed" || continue
    fi
    printf '%s/%s\n' "$target_repo" "$name"
  done

  official=$work/official
  LC_ALL=C pacman --config "$work/transaction.conf" --dbpath "$work/db" -Sl 2>/dev/null |
    awk -v candidate="$candidate_repo" '$1 != candidate { print $2 }' | LC_ALL=C sort -u >"$official"
  : >"$work/kept"
  for retired in "${retired_repos[@]}"; do
    [[ -f $pacman_db/sync/$retired.db ]] || continue
    LC_ALL=C pacman --config "$pacman_conf" --dbpath "$pacman_db" -Sl "$retired" 2>/dev/null |
      while read -r _ name version _; do
        [[ $(installed_version "$name" "$installed") == "$version" ]] || continue
        [[ " $target_packages " != *" $name "* ]] || continue
        if grep -Fxq "$name" "$official"; then
          printf '%s\n' "$name"
        else
          printf '%s %s\n' "$name" "$version" >>"$work/kept"
        fi
      done
  done

  : >"$work/allowed-removals"
  for name in $tester_replaced; do
    [[ -z $(installed_version "$name" "$installed") ]] || printf '%s\n' "$name" >>"$work/allowed-removals"
  done
}

# The collaboration repository's pending-sync marker outlives its repository.
tester_retire() {
  rm -f "$R/var/lib/omarchy/migrations/omarchy-aarch64-sync-pending"
  if [[ -s $plan/kept ]]; then
    say "Kept, with no official build: $(awk '{ print $1 }' "$plan/kept" | xargs)"
  fi
}
