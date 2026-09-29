#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

upgrade_to_quattro_mac="$ROOT/bin/omarchy-upgrade-to-quattro-mac"

function_body() {
  awk -v name="$1" '$0 == name "() {" { inside = 1; next } inside && $0 == "}" { exit } inside' "$upgrade_to_quattro_mac"
}

# Quattro renamed the setup entry points, and set -e turns a call to a command
# that no longer ships into a half-finished upgrade: the checkout, the system
# symlinks, and the Hyprland config are already replaced by the time this runs.
# Scoped to the function body so the retired package names stay out of it.
setup_body=$(function_body run_quattro_setup)
[[ -n $setup_body ]] || fail "the Mac Quattro upgrade has a run_quattro_setup step"
while read -r command_name; do
  [[ -n $command_name ]] || continue
  [[ -x "$ROOT/bin/$command_name" ]] ||
    fail "Mac Quattro upgrade only calls setup commands that ship in bin/" "missing: $command_name"
done < <(grep -oE '\bomarchy-[a-z0-9-]+' <<<"$setup_body" | sort -u)
pass "Mac Quattro upgrade only calls setup commands that ship in bin/"

grep -F 'sudo omarchy-apply-system --install-user "$USER" --upgrade' "$upgrade_to_quattro_mac" >/dev/null ||
  fail "Mac Quattro upgrade applies system setup as root"
grep -F 'omarchy-provision-user --force' "$upgrade_to_quattro_mac" >/dev/null ||
  fail "Mac Quattro upgrade finalizes the user without sudo"
pass "Mac Quattro upgrade runs system setup as root and user setup as the user"

# Naming them keeps the 3.x spellings from creeping back in a later merge.
if grep -qE 'omarchy-setup-system|omarchy-finalize-user' "$upgrade_to_quattro_mac"; then
  fail "Mac Quattro upgrade does not call the retired 3.x command names"
fi
pass "Mac Quattro upgrade does not call the retired 3.x command names"

# Issue #200: the ref used to default to main, so a no-argument run checked out
# 3.8.2, installed packages against it, and aborted mid-upgrade on the first
# missing Quattro file — leaving the machine half-migrated.
grep -F 'upgrade_ref="${OMARCHY_UPGRADE_REF:-quattro}"' "$upgrade_to_quattro_mac" >/dev/null ||
  fail "Mac Quattro upgrade defaults to the quattro ref" "expected: upgrade_ref=\"\${OMARCHY_UPGRADE_REF:-quattro}\""
pass "Mac Quattro upgrade defaults to the quattro ref"

validate_body=$(function_body validate_quattro_tree)
[[ -n $validate_body ]] || fail "the Mac Quattro upgrade validates the selected tree"

# The validator must run after the checkout switch but before packages are
# installed or anything under /usr and /etc is written.
main_body=$(function_body main)
[[ $main_body == *install_quattro_packages* ]] ||
  fail "main still installs the Quattro package set"
steps_before_install=${main_body%%install_quattro_packages*}
[[ $steps_before_install == *switch_checkout_to_quattro* && $steps_before_install == *validate_quattro_tree* ]] ||
  fail "the tree validator runs before any package or system changes"
pass "the tree validator runs before any package or system changes"

# Exercise the validator itself against fake trees: a 3.x tree must be rejected,
# a Quattro-shaped one accepted. The function reads $checkout/$upgrade_ref and
# reports through fail(), so stub that out for the extraction run.
check_tree() {
  local tree_version="$1" description="$2" expect="$3" drop_path="${4:-}" status workdir

  workdir=$(mktemp -d)
  mkdir -p "$workdir/bin" "$workdir/etc/profile.d" "$workdir/default/uwsm/env.d" \
    "$workdir/default/environment.d" "$workdir/install"
  printf '%s\n' "$tree_version" >"$workdir/version"
  : >"$workdir/etc/profile.d/omarchy.sh"
  : >"$workdir/default/uwsm/env.d/10-omarchy"
  : >"$workdir/default/environment.d/10-omarchy-fcitx.conf"
  : >"$workdir/install/omarchy-base.packages"
  printf '#!/bin/bash\n' >"$workdir/bin/omarchy-apply-system"
  printf '#!/bin/bash\n' >"$workdir/bin/omarchy-provision-user"
  chmod +x "$workdir/bin/omarchy-apply-system" "$workdir/bin/omarchy-provision-user"
  [[ -z $drop_path ]] || rm -f "$workdir/$drop_path"

  status=0
  (
    checkout=$workdir
    upgrade_ref=quattro
    log() { :; }
    fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
    # function_body hands back the bare body; re-wrap it into a definition.
    eval "validate_quattro_tree() {
$validate_body
}"
    validate_quattro_tree
  ) >/dev/null 2>&1 || status=$?
  rm -rf "$workdir"

  if [[ $expect == "reject" && $status == 0 ]]; then
    fail "the tree validator rejects a non-Quattro tree ($description)"
  elif [[ $expect == "accept" && $status != 0 ]]; then
    fail "the tree validator accepts a Quattro tree ($description)" "exit status: $status"
  fi
}

check_tree "3.8.2" "version 3.8.2" reject
# The failure #200 reported: a 4.x-shaped version is not enough on its own.
check_tree "4.0.0.alpha" "missing etc/profile.d/omarchy.sh" reject "etc/profile.d/omarchy.sh"
check_tree "4.0.0.alpha" "version 4.0.0.alpha" accept
pass "the tree validator only lets Quattro trees through"

# The curl one-liner is written out in both the script and the guide, so a
# branch rename can leave a 3.x user fetching an upgrade that no longer exists.
script_url=$(grep -oE 'https://[^ ]*omarchy-upgrade-to-quattro-mac' "$upgrade_to_quattro_mac" | head -1)
doc_url=$(grep -oE 'https://[^ ]*omarchy-upgrade-to-quattro-mac' "$ROOT/docs/upgrade-to-quattro.md" | head -1)
[[ -n $script_url && -n $doc_url ]] || fail "the upgrade one-liner appears in both the script and the guide"
[[ $script_url == "$doc_url" ]] ||
  fail "the upgrade one-liner agrees between script and guide" "script: $script_url
doc:    $doc_url"
pass "the upgrade one-liner agrees between the script and the guide"

# A pre-existing ARM repo stanza does not prove its sync database is current;
# stale metadata turns the later package phase into confusing 404s. Refreshing
# must therefore happen on both the add and already-present paths, and failure
# must stop before package installation rather than being downgraded to a warn.
repo_body=$(function_body ensure_arm_package_repo)
[[ $repo_body != *'grep -q '\''^\[omarchy-aarch64\]'\'' /etc/pacman.conf && return 0'* ]] ||
  fail "the Quattro upgrade refreshes an already-configured ARM repo"
grep -F 'sudo pacman -Sy --noconfirm' <<<"$repo_body" >/dev/null ||
  fail "the Quattro upgrade refreshes ARM package databases"
grep -F 'fail "Could not refresh package databases.' <<<"$repo_body" >/dev/null ||
  fail "the Quattro upgrade stops when the ARM package database cannot refresh"
if grep -F 'Could not refresh package databases after adding the ARM repo' <<<"$repo_body" >/dev/null; then
  fail "the Quattro upgrade does not continue on a failed ARM database refresh"
fi
pass "the Quattro upgrade refreshes and validates ARM package databases"

# Issue #208: the package pass attempted every name in the default set, so a 3.x
# machine spent hours on AUR builds install.sh deliberately skips -- and one of
# them, quickshell-git, fails outright on the pre-upgrade GL stack.
install_body=$(function_body install_quattro_packages)
[[ -n $install_body ]] || fail "the Mac Quattro upgrade has an install_quattro_packages step"

# Naming the matcher proves nothing: without the load the list is empty and the
# filter answers no to everything. Pin the call, its order, and the override.
install_code=$(grep -vE '^[[:space:]]*#' <<<"$install_body")
[[ $install_code == *load_unavailable_packages* ]] ||
  fail "the package pass loads the aarch64 unavailable list"
[[ ${install_code%%while read*} == *load_unavailable_packages* ]] ||
  fail "the unavailable list is loaded before the package loop reads it"
grep -qF '${OMARCHY_TRY_UNAVAILABLE:-0} != "1" ]] && package_is_unavailable_here' <<<"$install_code" ||
  fail "the filter runs on the loop and stays overridable with OMARCHY_TRY_UNAVAILABLE"
pass "the upgrade filters the package set through the aarch64 unavailable list"

# Exercise the matcher against a list on disk rather than trust its name.
matcher_probe=$(mktemp -d)
mkdir -p "$matcher_probe/install"
printf '# a comment\n\nlisted-package\n' >"$matcher_probe/install/omarchy-aarch64-unavailable.packages"
(
  checkout="$matcher_probe"
  eval "$(awk '/^load_unavailable_packages\(\) \{/,/^\}/' "$upgrade_to_quattro_mac")"
  eval "$(awk '/^package_is_unavailable_here\(\) \{/,/^\}/' "$upgrade_to_quattro_mac")"
  load_unavailable_packages
  package_is_unavailable_here listed-package || exit 1
  ! package_is_unavailable_here some-other-package || exit 1
) || fail "the unavailable matcher answers from the list on disk"
rm -rf "$matcher_probe"
pass "the unavailable matcher answers from the list on disk"

# Skipping quickshell-git is only safe where something else provides Quickshell.
# A packaged install gets it from the omarchy package; this layout installs no
# such package, so state the invariant rather than one spelling of it.
quickshell_git_skipped=0
if grep -qxF 'quickshell-git' "$ROOT/install/omarchy-aarch64-unavailable.packages"; then
  quickshell_git_skipped=1
fi
installs_quickshell=0
if grep -qE '^[[:space:]]*yay -S .*[[:space:]]quickshell([[:space:]]|$)' <<<"$install_code"; then
  installs_quickshell=1
fi
(( ! quickshell_git_skipped || installs_quickshell )) ||
  fail "quickshell-git is skipped and nothing installs quickshell: the upgrade leaves no shell"
pass "the upgrade always ends up with Quickshell installed"

# The default package pass records failures and continues, so the optional
# Apple recording fallback must do the same. Otherwise a missing ARM build or a
# transient AUR failure aborts after the checkout and system paths changed,
# leaving the 3.x machine half-upgraded. Capture the warning rather than
# relying on the subshell's exit status: Bash suppresses errexit in this
# conditional context, so the old bare yay call falsely passed.
optional_install_output=$(mktemp)
if ! (
  checkout="$ROOT"
  unavailable_packages=()
  load_unavailable_packages() { unavailable_packages=(); }
  package_is_unavailable_here() { return 1; }
  log() { :; }
  warn() { printf '%s\n' "$*" >>"$optional_install_output"; }
  yay() {
    [[ $* == *wf-recorder* ]] && return 1
    return 0
  }
  eval "install_quattro_packages() {
$install_body
}"
  install_quattro_packages
); then
  rm -f "$optional_install_output"
  fail "the Quattro upgrade continues when wf-recorder is unavailable"
fi
grep -qF 'wf-recorder' "$optional_install_output" || {
  rm -f "$optional_install_output"
  fail "the Quattro upgrade reports wf-recorder when it is unavailable"
}
rm -f "$optional_install_output"
pass "the Quattro upgrade continues and reports when wf-recorder is unavailable"

# Every other fatal step reports through fail(); a bare set -e abort here would
# die silently after the checkout has already been switched.
if (( installs_quickshell )); then
  grep -A1 -E '^[[:space:]]*yay -S .*[[:space:]]quickshell([[:space:]]|$)' <<<"$install_code" |
    grep -qF 'fail "' ||
    fail "a failed quickshell install reports through fail(), not a silent set -e abort"
  pass "a failed quickshell install reports through fail()"
fi

# Exercise the config seam in temporary homes. These probes intentionally load
# only the config functions: running the complete upgrade would require an ARM
# machine, pacman, yay, sudo, and a live checkout.
function_source() {
  awk -v name="$1" '
    $0 == name "() {" { inside = 1; depth = 1; next }
    inside {
      line = $0
      gsub(/\$\{[^}]*\}/, "", line)
      opens = gsub(/{/, "{", line)
      closes = gsub(/}/, "}", line)
      depth += opens - closes
      if (depth <= 0) exit
      print
    }
  ' "$upgrade_to_quattro_mac"
}

load_config_functions() {
  local name

  for name in \
    acquire_config_transition_lock \
    is_valid_backup_identity \
    owned_marker_matches_identity \
    write_state_marker \
    write_owned_marker \
    load_or_create_backup_identity \
    backup_user_config \
    config_backup_path \
    publish_config_transition \
    tree_state_matches \
    write_tree_state \
    load_tree_state \
    ensure_tree_backup \
    validate_tree_backup_if_present \
    validate_target_backup_if_present \
    publish_config_tree \
    replace_hyprland_config; do
    eval "$(printf '%s() {\n%s\n}' "$name" "$(function_source "$name")")"
  done
}

config_fixture() {
  local root="$1"

  HOME="$root/home"
  checkout="$root/checkout"
  upgrade_state_dir="$HOME/.local/state/omarchy/upgrade-to-quattro-mac"
  backup_identity_file="$upgrade_state_dir/backup-identity"
  backup_absent_file="$upgrade_state_dir/config-backup-absent"
  config_transition_file="$upgrade_state_dir/config-transition-complete"
  config_transition_lock="$upgrade_state_dir/config-transition.lock"
  hypr_backup_state_file="$upgrade_state_dir/hypr-backup-state"
  omarchy_backup_state_file="$upgrade_state_dir/omarchy-backup-state"
  backup_suffix=""
  mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy" "$checkout/config/hypr" "$checkout/config/omarchy"
  printf 'legacy\n' >"$HOME/.config/hypr/hyprland.conf"
  printf 'old omarchy\n' >"$HOME/.config/omarchy/user.conf"
  printf 'quattro\n' >"$checkout/config/hypr/hyprland.lua"
  printf 'shipped omarchy\n' >"$checkout/config/omarchy/default.conf"
}

config_copy_and_retry_probe() (
  local root identity backup_root stale_backup

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  log() { :; }
  flock() { return 0; }
  load_config_functions

  # An old-style backup is not owned by this run and must remain untouched.
  stale_backup="$HOME/.config.omarchy3.19990101000000.bak"
  mkdir "$stale_backup"
  printf 'stale\n' >"$stale_backup/old.conf"

  CP_FAIL=backup
  cp() {
    if [[ ${CP_FAIL:-} == backup && $* == *"$HOME/.config/."* ]]; then
      command cp "$@"
      CP_FAIL=
      return 1
    fi
    command cp "$@"
  }
  export CP_FAIL
  if ( backup_user_config ) >/dev/null 2>&1; then
    fail "backup copy failure unexpectedly succeeded"
  fi
  CP_FAIL=none
  identity=$(<"$backup_identity_file")
  [[ ! -e "$HOME/.config.omarchy3.$identity.bak.partial" ]] || fail "failed backup left a plausible partial backup"
  backup_user_config
  [[ $(<"$backup_identity_file") == "$identity" ]] || fail "backup retry allocated a second identity"
  backup_root="$HOME/.config.omarchy3.$identity.bak"
  [[ -f "$backup_root/.omarchy-upgrade-to-quattro-config-backup-complete" ]] || fail "backup retry did not publish its completion marker"
  [[ -f "$stale_backup/old.conf" ]] || fail "unrelated backup was modified"

  replace_hyprland_config
  [[ -f "$HOME/.config/hypr/hyprland.lua" ]] || fail "first config publication missed Hyprland"
  [[ -f "$HOME/.config/omarchy/default.conf" ]] || fail "first config publication missed Omarchy"
  [[ -f "$HOME/.config/omarchy/user.conf" ]] || fail "Omarchy stage dropped an unrelated user file"

  printf 'user repair\n' >"$HOME/.config/hypr/hyprland.lua"
  printf 'user omarchy repair\n' >"$HOME/.config/omarchy/default.conf"
  backup_user_config
  replace_hyprland_config
  grep -qx 'user repair' "$HOME/.config/hypr/hyprland.lua" || fail "user-repaired Hyprland config was replaced"
  grep -qx 'user omarchy repair' "$HOME/.config/omarchy/default.conf" || fail "user-repaired Omarchy config was replaced"
)
config_copy_and_retry_probe
pass "config backup retries preserve identity and ignore unrelated backups"

config_collision_probe() (
  local root base result

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  eval "$(printf '%s() {\n%s\n}' config_backup_path "$(function_source config_backup_path)")"
  base="$root/hypr.omarchy3.20260901010101-ABC123.bak"
  mkdir "$base"
  result=$(config_backup_path "$base")
  [[ $result == "$base.1" ]] || fail "timestamp collision did not select a unique backup path" "selected: $result"
  [[ -d $base ]] || fail "timestamp collision removed the existing backup"
)
config_collision_probe
pass "timestamp collisions do not overwrite existing backups"

config_stage_failure_probe() (
  local root

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  log() { :; }
  flock() { return 0; }
  load_config_functions
  backup_user_config
  CP_FAIL=stage
  cp() {
    if [[ ${CP_FAIL:-} == stage && $* == *"$checkout/config/hypr/."* ]]; then
      CP_FAIL=
      return 1
    fi
    command cp "$@"
  }
  export CP_FAIL
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "staged config copy failure unexpectedly succeeded"
  fi
  CP_FAIL=none
  [[ -f "$HOME/.config/hypr/hyprland.conf" ]] || fail "staged copy failure replaced active Hyprland"
  [[ ! -f "$config_transition_file" ]] || fail "staged copy failure marked transition complete"
  replace_hyprland_config
  [[ -f "$HOME/.config/hypr/hyprland.lua" ]] || fail "retry did not rebuild the failed stage"
)
config_stage_failure_probe
pass "staged config copy failure leaves active config intact for retry"

config_publication_retry_probe() (
  local root repair_root="" identity

  root=$(mktemp -d)
  trap 'rm -rf "$root" "$repair_root"' EXIT
  config_fixture "$root"
  log() { :; }
  flock() { return 0; }
  load_config_functions
  backup_user_config
  MV_FAIL=hypr
  mv() {
    if [[ ${MV_FAIL:-} == hypr && $2 == "$HOME/.config/hypr" ]]; then
      MV_FAIL=
      return 1
    fi
    command mv "$@"
  }
  export MV_FAIL
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "Hyprland publication failure unexpectedly succeeded"
  fi
  MV_FAIL=none
  [[ -f "$HOME/.config/omarchy/default.conf" ]] || fail "Omarchy was not published before Hyprland"
  identity=$(<"$backup_identity_file")
  [[ -f "$HOME/.config/hypr.omarchy3.$identity.bak/hyprland.conf" ]] || fail "Hyprland was not preserved before its publication"
  replace_hyprland_config
  [[ -f "$HOME/.config/hypr/hyprland.lua" ]] || fail "retry did not resume the exact staged Hyprland tree"

  # A user can repair the active legacy directory before retrying; Lua is the
  # adoption signal even if other legacy files remain.
  repair_root=$(mktemp -d)
  config_fixture "$repair_root"
  backup_user_config
  MV_FAIL=hypr
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "repair setup publication failure unexpectedly succeeded"
  fi
  MV_FAIL=none
  mkdir -p "$HOME/.config/hypr"
  printf 'repaired lua\n' >"$HOME/.config/hypr/hyprland.lua"
  printf 'repaired omarchy\n' >"$HOME/.config/omarchy/default.conf"
  replace_hyprland_config
  grep -qx 'repaired lua' "$HOME/.config/hypr/hyprland.lua" || fail "active repaired Hyprland was not adopted"
  grep -qx 'repaired omarchy' "$HOME/.config/omarchy/default.conf" || fail "active repaired Omarchy was recopied"
)
config_publication_retry_probe
pass "partial publication resumes safely and adopts repaired active Hyprland"

config_absent_retry_probe() (
  local root

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  HOME="$root/home"
  upgrade_state_dir="$HOME/.local/state/omarchy/upgrade-to-quattro-mac"
  backup_identity_file="$upgrade_state_dir/backup-identity"
  backup_absent_file="$upgrade_state_dir/config-backup-absent"
  config_transition_file="$upgrade_state_dir/config-transition-complete"
  config_transition_lock="$upgrade_state_dir/config-transition.lock"
  backup_suffix=""
  log() { :; }
  flock() { return 0; }
  load_config_functions

  backup_user_config
  [[ $(<"$backup_absent_file") == absent ]] || fail "missing ~/.config was not recorded"
  mkdir -p "$HOME/.config"
  printf 'created after absence\n' >"$HOME/.config/new.conf"
  backup_user_config
  [[ $(<"$backup_absent_file") == absent ]] || fail "absent marker changed on retry"
  [[ ! -e "$HOME/.config.omarchy3.$backup_suffix.bak" ]] || fail "absent retry created a backup after the config appeared"
)
config_absent_retry_probe
pass "an absent-config marker remains authoritative on retry"

config_lock_contention_probe() (
  local root

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  log() { :; }
  flock() { return 1; }
  load_config_functions
  if ( backup_user_config ) >/dev/null 2>&1; then
    fail "a held config transition lock was ignored"
  fi
  [[ ! -e "$backup_identity_file" ]] || fail "lock contention created a backup identity"

  rm -rf "$upgrade_state_dir"
  mkdir -p "$HOME/.local/state"
  ln -s "$root/foreign-state" "$upgrade_state_dir"
  if ( backup_user_config ) >/dev/null 2>&1; then
    fail "a symlinked state directory was accepted"
  fi
  rm -f "$upgrade_state_dir"
  mkdir -p "$upgrade_state_dir"
  ln -s "$backup_identity_file" "$config_transition_lock"
  if ( backup_user_config ) >/dev/null 2>&1; then
    fail "a symlinked transition lock was accepted"
  fi
)
config_lock_contention_probe
pass "config transition lock contention prevents a second invocation"

config_real_lock_probe() (
  local root script ready first_pid attempt lock_body

  if ! command -v flock >/dev/null 2>&1; then
    printf 'skip - real two-process flock probe requires flock\n'
    return 0
  fi

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  script=$(mktemp)
  ready="$root/ready"
  lock_body=$(function_source acquire_config_transition_lock)
  printf '%s\n' '#!/bin/bash' 'set -e' 'fail() { exit 1; }' \
    "upgrade_state_dir=$root/state" \
    "config_transition_lock=$root/state/config-transition.lock" \
    'acquire_config_transition_lock() {' \
    "$lock_body" \
    '}' \
    "acquire_config_transition_lock" \
    "touch $ready" \
    'sleep 2' >"$script"
  chmod +x "$script"
  "$script" &
  first_pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e $ready ]] && break
    sleep 0.02
  done
  [[ -e $ready ]] || fail "the first flock holder did not acquire the lock"
  if "$script"; then
    kill "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
    fail "a second process acquired the config transition lock"
  fi
  wait "$first_pid"
)
config_real_lock_probe
if command -v flock >/dev/null 2>&1; then
  pass "two production lock holders cannot overlap"
else
  pass "real two-process flock probe skipped without flock"
fi

state_marker_rejection_probe() (
  local root identity backup_root backup_marker stage stage_marker

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  log() { :; }
  flock() { return 0; }
  load_config_functions

  expect_backup_failure() {
    if ( backup_user_config ) >/dev/null 2>&1; then
      fail "a malformed Quattro backup marker was accepted"
    fi
  }
  backup_user_config
  identity=$(<"$backup_identity_file")
  backup_root="$HOME/.config.omarchy3.$identity.bak"
  backup_marker="$backup_root/.omarchy-upgrade-to-quattro-config-backup-complete"

  rm -rf "$backup_root"
  mkdir "$backup_root"
  printf 'foreign\n' >"$backup_marker"
  expect_backup_failure
  rm -rf "$backup_root"
  mkdir "$backup_root"
  ln -s "$backup_identity_file" "$backup_marker"
  expect_backup_failure

  rm -f "$backup_marker"
  printf '%s\n' "$identity" >"$backup_marker"
  rm -f "$backup_identity_file"
  ln -s "$backup_marker" "$backup_identity_file"
  expect_backup_failure

  rm -f "$backup_identity_file"
  printf '%s\n' "$identity" >"$backup_identity_file"
  stage="$HOME/.config.omarchy3.$identity.quattro-config.partial"
  stage_marker="$stage/.omarchy-upgrade-to-quattro-config-complete"
  rm -rf "$stage"
  mkdir -p "$stage/hypr" "$stage/omarchy"
  printf 'foreign\n' >"$stage_marker"
  rm -rf "$HOME/.config/hypr"
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "a foreign stage marker was accepted"
  fi
  rm -f "$stage_marker"
  ln -s "$backup_identity_file" "$stage_marker"
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "a symlinked stage marker was accepted"
  fi

  rm -rf "$stage"
  mkdir -p "$HOME/.config/hypr"
  printf 'repaired lua\n' >"$HOME/.config/hypr/hyprland.lua"
  rm -f "$config_transition_file"
  printf '19990101000000-ABC123\npublished\n' >"$config_transition_file"
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "a wrong-content transition marker was accepted"
  fi
  rm -f "$config_transition_file"
  ln -s "$backup_identity_file" "$config_transition_file"
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "a symlinked transition marker was accepted"
  fi
)
state_marker_rejection_probe
pass "foreign and symlinked identity markers are rejected"

config_stage_shape_probe() (
  local root identity stage stage_marker

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  log() { :; }
  flock() { return 0; }
  load_config_functions
  backup_user_config
  identity=$(<"$backup_identity_file")
  stage="$HOME/.config.omarchy3.$identity.quattro-config.partial"
  stage_marker="$stage/.omarchy-upgrade-to-quattro-config-complete"
  mkdir -p "$stage/hypr" "$stage/omarchy"
  printf '%s\n' "$identity" >"$stage_marker"
  rm -f "$HOME/.config/hypr/hyprland.conf"
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "a completed stage with the wrong shape was accepted"
  fi
)
config_stage_shape_probe
pass "completed stages must contain both owned config trees"

mixed_hyprland_adoption_probe() (
  local root

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  log() { :; }
  flock() { return 0; }
  printf 'user Lua repair\n' >"$HOME/.config/hypr/hyprland.lua"
  load_config_functions
  backup_user_config
  replace_hyprland_config
  grep -qx 'user Lua repair' "$HOME/.config/hypr/hyprland.lua" || fail "mixed active Hyprland config was replaced"
  grep -qx 'legacy' "$HOME/.config/hypr/hyprland.conf" || fail "mixed legacy Hyprland config was discarded"
  grep -qx 'old omarchy' "$HOME/.config/omarchy/user.conf" || fail "mixed active Omarchy config was discarded"
)
mixed_hyprland_adoption_probe
pass "mixed Hyprland configs are adopted with both trees preserved"

config_symlink_convergence_probe() (
  local root external hypr_target omarchy_target identity

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  external="$root/external"
  hypr_target="$external/hypr-target"
  omarchy_target="$external/omarchy-target"
  mkdir -p "$hypr_target" "$omarchy_target"
  printf 'external legacy hypr\n' >"$hypr_target/hyprland.conf"
  printf 'external legacy omarchy\n' >"$omarchy_target/user.conf"
  rm -rf "$HOME/.config/hypr" "$HOME/.config/omarchy"
  ln -s "$hypr_target" "$HOME/.config/hypr"
  ln -s "$omarchy_target" "$HOME/.config/omarchy"
  log() { :; }
  flock() { return 0; }
  load_config_functions
  backup_user_config
  identity=$(<"$backup_identity_file")
  replace_hyprland_config
  [[ -L "$HOME/.config/hypr" && $(readlink "$HOME/.config/hypr") == "$hypr_target" ]] || fail "Hyprland symlink was replaced"
  [[ -L "$HOME/.config/omarchy" && $(readlink "$HOME/.config/omarchy") == "$omarchy_target" ]] || fail "Omarchy symlink was replaced"
  [[ -f "$HOME/.config/hypr.omarchy3.$identity.bak/hyprland.conf" ]] || fail "dereferenced Hyprland target was not backed up"
  [[ -f "$HOME/.config/omarchy.omarchy3.$identity.bak/user.conf" ]] || fail "dereferenced Omarchy target was not backed up"
  [[ -f "$hypr_target.omarchy3.$identity.bak/hyprland.conf" ]] || fail "external Hyprland target backup was not retained"
  [[ -f "$omarchy_target.omarchy3.$identity.bak/user.conf" ]] || fail "external Omarchy target backup was not retained"
  [[ -f "$hypr_target/hyprland.lua" && -f "$omarchy_target/default.conf" ]] || fail "symlink targets did not converge to Quattro config"
)
config_symlink_convergence_probe
pass "legacy config symlinks remain links while their targets converge safely"

config_symlink_dangling_retry_probe() (
  local root external hypr_target omarchy_target identity target_backup marker fail_marker_path

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  external="$root/external"
  hypr_target="$external/hypr-target"
  omarchy_target="$external/omarchy-target"
  mkdir -p "$hypr_target" "$omarchy_target"
  printf 'external legacy hypr\n' >"$hypr_target/hyprland.conf"
  printf 'external legacy omarchy\n' >"$omarchy_target/user.conf"
  rm -rf "$HOME/.config/hypr" "$HOME/.config/omarchy"
  ln -s "$hypr_target" "$HOME/.config/hypr"
  ln -s "$omarchy_target" "$HOME/.config/omarchy"
  log() { :; }
  flock() { return 0; }
  load_config_functions
  backup_user_config
  identity=$(<"$backup_identity_file")
  target_backup="$(readlink -f "$hypr_target").omarchy3.$identity.bak"
  fail_marker_path="$target_backup/.omarchy-upgrade-to-quattro-target-backup-complete"
  eval "$(printf '%s() {\n%s\n}' write_owned_marker_impl "$(function_source write_owned_marker)")"
  write_owned_marker() {
    if [[ $1 == "$fail_marker_path" ]]; then
      exit 77
    fi
    write_owned_marker_impl "$@"
  }
  if ( replace_hyprland_config ); then
    fail "dangling symlink interruption unexpectedly succeeded"
  fi
  marker="$target_backup/.omarchy-upgrade-to-quattro-target-backup-complete"
  [[ -L "$HOME/.config/hypr" && $(readlink "$HOME/.config/hypr") == "$hypr_target" ]] || fail "dangling interruption replaced Hyprland link"
  [[ ! -e "$hypr_target" && -d "$target_backup" && ! -e "$marker" ]] || fail "dangling interruption did not leave the recorded target boundary" "target=$(ls -ld "$hypr_target" 2>&1); backup=$(ls -ld "$target_backup" 2>&1); marker=$(ls -l "$marker" 2>&1)"
  [[ $(readlink -f "$HOME/.config/hypr") == "$(sed -n '3p' "$hypr_backup_state_file")" ]] || fail "readlink -f did not resolve the recorded dangling symlink" "link=$(readlink -f "$HOME/.config/hypr"); recorded=$(sed -n '3p' "$hypr_backup_state_file")"
  load_config_functions
  replace_hyprland_config
  [[ -L "$HOME/.config/hypr" && -f "$hypr_target/hyprland.lua" ]] || fail "dangling symlink retry did not converge"
  [[ -f "$target_backup/hyprland.conf" ]] || fail "symlink publication retry discarded external legacy Hyprland content"
)
config_symlink_dangling_retry_probe
pass "dangling symlink publication retries from its recorded boundary"

config_symlink_published_retry_probe() (
  local root external hypr_target omarchy_target identity target_backup

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  external="$root/external"
  hypr_target="$external/hypr-target"
  omarchy_target="$external/omarchy-target"
  mkdir -p "$hypr_target" "$omarchy_target"
  printf 'external legacy hypr\n' >"$hypr_target/hyprland.conf"
  printf 'external legacy omarchy\n' >"$omarchy_target/user.conf"
  rm -rf "$HOME/.config/hypr" "$HOME/.config/omarchy"
  ln -s "$hypr_target" "$HOME/.config/hypr"
  ln -s "$omarchy_target" "$HOME/.config/omarchy"
  log() { :; }
  flock() { return 0; }
  load_config_functions
  backup_user_config
  identity=$(<"$backup_identity_file")
  target_backup="$hypr_target.omarchy3.$identity.bak"
  eval "$(printf '%s() {\n%s\n}' write_tree_state_impl "$(function_source write_tree_state)")"
  write_tree_state() {
    if [[ $1 == "$hypr_backup_state_file" && $5 == published ]]; then
      exit 78
    fi
    write_tree_state_impl "$@"
  }
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "post-swap state interruption unexpectedly succeeded"
  fi
  [[ -f "$hypr_target/hyprland.lua" ]] || fail "post-swap interruption did not leave the published target"
  [[ -f "$target_backup/.omarchy-upgrade-to-quattro-target-backup-complete" ]] || fail "post-swap interruption lost the owned target backup"
  load_config_functions
  publish_config_tree hypr "$HOME/.config.omarchy3.$identity.quattro-config.partial/hypr" "$HOME/.config/hypr" "$HOME/.config/hypr.omarchy3.$identity.bak" "$HOME/.config.omarchy3.$identity.hypr-publish.partial" "$hypr_backup_state_file"
  [[ -f "$hypr_target/hyprland.lua" && -f "$target_backup/hyprland.conf" ]] || fail "published target retry changed the target or lost its backup"
  [[ ! -e "$target_backup.1" ]] || fail "published target retry allocated another target backup"
)
config_symlink_published_retry_probe
pass "completed symlink publication is adopted from owned-backup state"

config_symlink_repair_after_move_probe() (
  local root external hypr_target hypr_target_canonical omarchy_target identity target_backup repair_temp_path

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  external="$root/external"
  hypr_target="$external/hypr-target"
  omarchy_target="$external/omarchy-target"
  mkdir -p "$hypr_target" "$omarchy_target"
  hypr_target_canonical="$(readlink -f "$hypr_target")"
  printf 'external legacy hypr\n' >"$hypr_target/hyprland.conf"
  printf 'external legacy omarchy\n' >"$omarchy_target/user.conf"
  rm -rf "$HOME/.config/hypr" "$HOME/.config/omarchy"
  ln -s "$hypr_target" "$HOME/.config/hypr"
  ln -s "$omarchy_target" "$HOME/.config/omarchy"
  log() { :; }
  flock() { return 0; }
  load_config_functions
  backup_user_config
  identity=$(<"$backup_identity_file")
  target_backup="$hypr_target.omarchy3.$identity.bak"
  repair_temp_path="$(readlink -f "$external")/.omarchy3.$identity.hypr-publish.partial"
  mv() {
    if [[ $1 == "$repair_temp_path" && $2 == "$hypr_target_canonical" ]]; then
      exit 79
    fi
    command mv "$@"
  }
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "symlink repair boundary unexpectedly succeeded"
  fi
  [[ -L "$HOME/.config/hypr" && ! -e "$hypr_target" && -f "$target_backup/.omarchy-upgrade-to-quattro-target-backup-complete" ]] || fail "symlink repair boundary was not staged after the target move"
  mkdir "$hypr_target"
  printf 'user repaired target\n' >"$hypr_target/repaired.conf"
  load_config_functions
  publish_config_tree hypr "$HOME/.config.omarchy3.$identity.quattro-config.partial/hypr" "$HOME/.config/hypr" "$HOME/.config/hypr.omarchy3.$identity.bak" "$HOME/.config.omarchy3.$identity.hypr-publish.partial" "$hypr_backup_state_file"
  grep -qx 'user repaired target' "$hypr_target/repaired.conf" || fail "repaired symlink target was replaced"
  [[ ! -e "$target_backup.1" ]] || fail "symlink repair allocated another target backup"
)
config_symlink_repair_after_move_probe
pass "repaired symlink targets are preserved after the target move"

config_regular_repair_after_move_probe() (
  local root identity backup_root temporary

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  log() { :; }
  flock() { return 0; }
  load_config_functions
  backup_user_config
  identity=$(<"$backup_identity_file")
  backup_root="$HOME/.config/hypr.omarchy3.$identity.bak"
  temporary="$HOME/.config.omarchy3.$identity.hypr-publish.partial"
  mv() {
    if [[ $1 == "$temporary" && $2 == "$HOME/.config/hypr" ]]; then
      exit 80
    fi
    command mv "$@"
  }
  if ( replace_hyprland_config ) >/dev/null 2>&1; then
    fail "regular repair boundary unexpectedly succeeded"
  fi
  [[ ! -e "$HOME/.config/hypr" && -f "$backup_root/.omarchy-upgrade-to-quattro-config-tree-backup-complete" ]] || fail "regular repair boundary was not staged after the active move"
  mkdir "$HOME/.config/hypr"
  printf 'user repaired regular tree\n' >"$HOME/.config/hypr/repaired.conf"
  load_config_functions
  publish_config_tree hypr "$HOME/.config.omarchy3.$identity.quattro-config.partial/hypr" "$HOME/.config/hypr" "$backup_root" "$temporary" "$hypr_backup_state_file"
  grep -qx 'user repaired regular tree' "$HOME/.config/hypr/repaired.conf" || fail "repaired regular tree was replaced"
  [[ ! -e "$backup_root.1" ]] || fail "regular repair allocated another backup"
)
config_regular_repair_after_move_probe
pass "repaired regular config trees are preserved after the active move"

config_tree_ownership_probe() (
  local root identity stale_backup backup_count

  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT
  config_fixture "$root"
  log() { :; }
  flock() { return 0; }
  load_config_functions
  identity=20260901203000-ABC123
  mkdir -p "$upgrade_state_dir"
  stale_backup="$HOME/.config/hypr.omarchy3.$identity.bak"
  mkdir "$stale_backup"
  printf 'unowned\n' >"$stale_backup/stale.conf"
  printf '%s\n' "$identity" >"$backup_identity_file"
  backup_user_config
  replace_hyprland_config
  [[ -f "$stale_backup/stale.conf" ]] || fail "unowned same-identity backup was overwritten"
  [[ -f "$HOME/.config/hypr.omarchy3.$identity.bak.1/hyprland.conf" ]] || fail "same-identity backup collision was not avoided"
  backup_count=$(find "$HOME" -maxdepth 1 -name "hypr.omarchy3.$identity.bak*" | wc -l)
  replace_hyprland_config
  [[ $(find "$HOME" -maxdepth 1 -name "hypr.omarchy3.$identity.bak*" | wc -l) == "$backup_count" ]] || fail "completed retry created an extra Hyprland backup"
)
config_tree_ownership_probe
pass "per-tree backup ownership is identity-bound and completed retries are stable"
