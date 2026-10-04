# What a fresh install sets up, done for a migrated Mac: its default packages,
# the Mac services, the repairs and, for every Omarchy user, the settled
# migrations, the units first run enables and the user setup.
# shellcheck disable=SC2154

# The default packages the aarch64 and Apple lists add, where they are missing
# and a repository carries them (the base list's applications stay the owner's
# choice). Firmware among them rebuilds the initramfs and the UKI through
# pacman's hooks, so the boot files are checked again.
install_defaults() {
  local generic apple available name missing=() absent=() output
  if ! command -v omarchy-pkg-defaults >/dev/null; then
    say "This Omarchy has no omarchy-pkg-defaults: the default packages were not checked"
    return 0
  fi
  generic=$(env OMARCHY_PATH="$R/usr/share/omarchy" omarchy-pkg-defaults generic) &&
    apple=$(env OMARCHY_PATH="$R/usr/share/omarchy" omarchy-pkg-defaults apple-silicon) ||
    die "cannot read the Apple Silicon default packages"
  available=$(LC_ALL=C pacman --config "$pacman_conf" --dbpath "$pacman_db" -Sl | awk '{ print $2 }') ||
    die "cannot read the repositories' packages"
  while read -r name; do
    [[ -n $name ]] && ! grep -Fxq -- "$name" <<<"$generic" || continue
    LC_ALL=C pacman --config "$pacman_conf" --dbpath "$pacman_db" -Qq "$name" >/dev/null 2>&1 && continue
    if grep -Fxq -- "$name" <<<"$available"; then
      missing+=("$name")
    else
      absent+=("$name")
    fi
  done <<<"$apple"
  (( ${#absent[@]} == 0 )) || say "No repository carries these default packages, so they stay missing: ${absent[*]}"
  (( ${#missing[@]} )) || return 0
  say "Installing the default packages a fresh install has: ${missing[*]}"
  pacman_run --config "$pacman_conf" --dbpath "$pacman_db" -S --noconfirm "${missing[@]}" ||
    die "cannot install the default packages: ${missing[*]}"
  output=$(boot_check_pending linux-aurora 2>&1) || die "the boot files do not check after the default packages: $(tail -n 1 <<<"$output")"
}

# --- User setup ------------------------------------------------------------------
#
# Each Omarchy user gets the settled migrations, the units first run enables
# and the Mac user setup. What fails for one user (a broken home, a setup that
# exits nonzero) never stops the migration: it is kept in user-pending, a
# "user item" line each, and runs again at every later run and boot until it
# succeeds. The post-reboot unit stays enabled for that.

# One item of a user's setup: settle:NAMES, a unit first run enables,
# retire-leftovers or setup-user. A pending settle keeps the names it was
# given, so a retry after the plan moved on records the same ones.
apply_user_item() {
  local user=$1 home=$2 item=$3
  case $item in
    settle:*) settle_migrations "$user" "$home" "${item#settle:}" ;;
    retire-leftovers) retire_user_leftovers "$user" "$home" ;;
    setup-user) as_user "$user" "$R$home" omarchy-lifecycle-dispatch setup-user >/dev/null ;;
    *) enable_user_unit "$user" "$home" "$item" ;;
  esac
}

# The user's setup; prints what failed, one item a line.
setup_user() {
  local user=$1 home=$2 item items=("settle:$(settled_for "$user" "$home")")
  if [[ -f $plan/user-units ]]; then
    for item in $fresh_user_units; do
      grep -Fxq "$item" "$plan/user-units" || items+=("$item")
    done
  fi
  for item in "${items[@]}" retire-leftovers setup-user; do
    apply_user_item "$user" "$home" "$item" || printf '%s\n' "$item"
  done
}

# Replaces the pending record with FILE's lines, or removes it when FILE is empty.
record_user_pending() {
  if [[ -s $1 ]]; then
    LC_ALL=C sort -u "$1" | durable_write "$user_pending" || die "cannot record the pending user setup"
  else
    rm -f "$user_pending"
  fi
}

# "user item; ..." for messages, a settle item without its names.
pending_summary() {
  awk '{ item = $2; sub(/:.*/, "", item); print $1 " " item }' "$user_pending" | paste -sd';' | sed 's/;/; /g'
}

# Runs the pending items again, only those, so nothing a user turned off since
# comes back. An account that is gone or no longer uses Omarchy is dropped.
# Fails while any item is still pending.
retry_user_pending() {
  local user home item left
  [[ -s $user_pending ]] || return 0
  rm -f "$state"/user-pending.??????
  left=$(mktemp "$state/user-pending.XXXXXX") || die "cannot record the pending user setup"
  while read -r user item; do
    home=$(omarchy_users | awk -v user="$user" '$1 == user { print $2; exit }')
    [[ -n $home && -n $item ]] || continue
    apply_user_item "$user" "$home" "$item" </dev/null || printf '%s %s\n' "$user" "$item" >>"$left"
  done <"$user_pending"
  record_user_pending "$left"
  rm -f "$left"
  if [[ -s $user_pending ]]; then
    say "User setup still pending, retried at the next run or boot: $(pending_summary)"
    return 1
  fi
  say "The pending user setup is done"
}

# Outside a completed migration's cleanup: pending user setup runs again, and
# once none is left the post-reboot unit is released unless a migration is
# waiting for its reboot.
retry_user_pending_now() {
  [[ -s $user_pending ]] || return 0
  # A migration still under way keeps the unit that resumes it.
  if retry_user_pending && [[ ! -e $reboot_pending ]] && ! past_boundary; then
    release_verify_unit
  fi
}

# A migrated Mac ends as a fresh install does: with its default packages, the
# Mac services the image's hardware setup enables, the repairs above and, for
# every Omarchy user, the migrations a fresh image records as done, the units
# first run enables and the Mac user setup. A unit the Mac already had before
# the migration is taken to be off by choice and stays off; a plan frozen
# before that was recorded enables none. The reboot that follows brings up
# what probes only at boot, such as the video decoder.
step_defaults() {
  local user home item pending
  install_defaults
  interrupt_for_test mid defaults
  retire_system_leftovers
  omarchy-lifecycle-dispatch setup-system >/dev/null || die "setup-system (omarchy-lifecycle-dispatch) could not set up the Mac's services"
  repair_system
  interrupt_for_test mid user-setup
  # What an earlier migration left pending stays pending until it succeeds.
  retry_user_pending || :
  rm -f "$state"/user-pending.??????
  pending=$(mktemp "$state/user-pending.XXXXXX") || die "cannot record the pending user setup"
  [[ ! -f $user_pending ]] || cat "$user_pending" >"$pending"
  while read -r user home; do
    [[ -n $user ]] || continue
    while read -r item; do
      [[ -n $item ]] || continue
      say "Could not apply $item for $user; it runs again after the reboot"
      printf '%s %s\n' "$user" "$item" >>"$pending"
    done < <(setup_user "$user" "$home" </dev/null)
  done < <(omarchy_users)
  record_user_pending "$pending"
  rm -f "$pending"
}
