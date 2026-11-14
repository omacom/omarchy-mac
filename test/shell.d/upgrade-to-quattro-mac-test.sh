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

if grep -qE 'https://[^ ]*omarchy-upgrade-to-quattro-mac' "$ROOT/docs/upgrade-to-quattro.md"; then
  fail "the guide no longer publishes the retired upgrade one-liner"
fi
grep -qF 'https://omarchy.org/manual/mac-support/' "$ROOT/docs/upgrade-to-quattro.md" ||
  fail "the guide points 3.x users to the Mac manual"
pass "the guide points 3.x users to the Mac manual instead of the upgrade"

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
