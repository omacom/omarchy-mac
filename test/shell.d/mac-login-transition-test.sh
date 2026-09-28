#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

upgrade="$ROOT/bin/omarchy-upgrade-to-quattro-mac"
migration="$ROOT/migrations/1784417043.sh"
helper="$ROOT/bin/omarchy-system-wait-for-display"
fixture_user=$(id -un)

[[ -x $helper ]] || fail "the shared display guard is executable"
grep -qF '# omarchy:hidden=true' "$helper" || fail "the shared display guard is hidden"
grep -qF '/usr/bin/omarchy-system-wait-for-display' "$migration" || fail "the migration invokes the shared display guard"
! grep -qF '/usr/local/bin/omarchy-wait-for-display' "$migration" || fail "the migration does not embed the retired display guard"
pass "the Mac login transition has one display-guard authority"

grep -qF 'ConditionPathExists=!/etc/systemd/system/display-manager.service' "$upgrade" || fail "the seamless interlock is negated against the display-manager alias"
grep -qF 'sudo env OMARCHY_PATH="$checkout" "$checkout/bin/omarchy-mac-setup" --autologin --user "$autologin_user"' "$upgrade" || fail "the transition reuses mac-setup with the selected user"
grep -qF 'sudo systemctl disable omarchy-seamless-login.service' "$upgrade" || fail "cleanup disables seamless-login without --now"
! grep -qF 'systemctl restart sddm' "$upgrade" || fail "the transition does not restart a login owner"
grep -qF 'systemd_state_output=$(sudo env LC_ALL=C systemctl is-enabled' "$upgrade" || fail "systemd state captures command output"
grep -qF 'systemd_state_status != 0' "$upgrade" || fail "disabled and not-found require a nonzero systemd status"
grep -qF 'seamless_unit_name=omarchy-seamless-login.service' "$upgrade" || fail "systemd state uses the unit name"
! grep -qF 'capture_systemd_state "$seamless_unit"' "$upgrade" || fail "systemd state does not pass an absolute unit path"
grep -qF 'require_sddm_alias' "$upgrade" || fail "cleanup requires a canonical SDDM alias"
grep -qF 'OMARCHY_LOGIN_TRANSITION_INTERRUPT_AFTER_UNIT' "$upgrade" || fail "cleanup exposes the post-unit-removal interruption seam"
grep -qF 'temporary=$(sudo mktemp "$parent/.omarchy-login.XXXXXX")' "$upgrade" || fail "drop-in temp files share the destination filesystem"
grep -qF 'sudo mv -f "$temporary" "$destination"' "$upgrade" || fail "drop-ins publish with an atomic rename"
grep -qF 'install_login_interlock' "$upgrade" || fail "the early interlock path is present"
grep -qF 'verify_sddm_display_guard' "$upgrade" || fail "final validation checks the SDDM guard"
main_body=$(awk '/^main\(\) \{/{inside=1} inside{print} /^\}/{if (inside) exit}' "$upgrade")
[[ ${main_body%%prepare_login_transition*} != *run_quattro_setup* ]] || fail "login preparation precedes Quattro setup"
[[ $main_body == *prepare_login_transition*run_quattro_setup*cleanup_login_transition* ]] || fail "login handoff is ordered prepare, setup, cleanup"
prepare_body=$(sed -n '/^prepare_login_transition() {/,/^legacy_artifacts_present() {/p' "$upgrade" | sed '$d')
[[ $prepare_body == *install_login_interlock*install_sddm_display_guard* ]] || fail "the interlock precedes SDDM preparation"
pass "the transition orders the interlock before setup and cleanup after setup"

# Load only the transition functions into a disposable process. This avoids the
# script's host checks while exercising the real parser and alias validation.
defs=$(sed -n '/^wire_system_paths() {/,/^main() {/p' "$upgrade" | sed '$d')
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
mkdir -p "$probe/system" "$probe/admin" "$probe/checkout/bin"
printf '#!/bin/bash\n' >"$probe/checkout/bin/omarchy-system-wait-for-display"
chmod +x "$probe/checkout/bin/omarchy-system-wait-for-display"

(
  set -euo pipefail
  log() { :; }
  fail() { printf '%s\n' "$*" >&2; exit 1; }
  sudo() { "$@"; }
  eval "$defs"
  sddm_system_conf_dir="$probe/system"
  sddm_admin_conf_dir="$probe/admin"
  sddm_conf="$probe/etc.conf"
  printf '[Wayland]\n# SessionDir=/bad/comment\nSessionDir=/bad/earlier\n' >"$probe/system/10-base.conf"
  printf '[Wayland]\n; SessionDir=/bad/comment\nSessionDir="/usr/share/wayland-sessions"\n' >"$probe/admin/90-local.conf"
  validate_sddm_session_dir
  [[ -z $sddm_session_dir || $sddm_session_dir == "/usr/share/wayland-sessions" ]]
  printf '[Wayland]\nSessionDir=/custom/sessions\n' >"$probe/admin/99-custom.conf"
  if (validate_sddm_session_dir); then
    exit 1
  fi
) || fail "layered SDDM SessionDir parsing handles comments and final custom overrides"
pass "layered SDDM SessionDir parsing handles comments and final custom overrides"

(
  set -euo pipefail
  log() { :; }
  fail() { printf '%s\n' "$*" >&2; exit 1; }
  sudo() { "$@"; }
  eval "$defs"
  target="$(cd "$probe" && pwd -P)/sddm.fragment"
  alias="$probe/display-manager.service"
  : >"$target"
  ln -s "$target" "$alias"
  sddm_alias="$alias"
  systemctl_bin="$probe/systemctl"
  printf '#!/bin/bash\ncase "$*" in\n  *"show -p FragmentPath"*) printf "%%s\\n" "%s" ;;\n  *"is-enabled sddm.service"*) printf "enabled\\n" ;;\n  *) exit 1 ;;\nesac\n' "$target" >"$systemctl_bin"
  chmod +x "$systemctl_bin"
  PATH="$(dirname "$systemctl_bin"):$PATH"
  validate_sddm_alias
  rm "$alias"
  ln -s "$probe/foreign.fragment" "$alias"
  if (validate_sddm_alias); then
    exit 1
  fi
) || fail "the alias gate accepts only the canonical enabled SDDM target"
pass "the alias gate accepts only the canonical enabled SDDM target"

# Make the polling loop empty so the fail-open path is exercised without a
# fifteen-second test delay or dependence on the verifier's /sys tree.
stub_bin="$probe/stub-bin"
mkdir "$stub_bin"
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/seq"
chmod +x "$stub_bin/seq"
PATH="$stub_bin:$PATH" "$helper"
pass "the Apple display guard fails open when the probe times out"

# Exercise the transition functions against a complete disposable systemd
# model. Every path below is redirected into this fixture; the host's /etc and
# systemd manager are never consulted.
fixture() {
  local initial_state="$1" artifacts="${2:-yes}" alias_mode="${3:-valid}"
  case_root=$(mktemp -d "$probe/case.XXXXXX")
  case_root=$(cd "$case_root" && pwd -P)
  export USER="$fixture_user"
  mkdir -p "$case_root/system" "$case_root/admin" "$case_root/checkout/bin" "$case_root/sessions"
  printf 'fragment\n' >"$case_root/sddm.fragment"
  printf '[Desktop Entry]\nName=Omarchy\n' >"$case_root/sessions/omarchy.desktop"
  cat >"$case_root/checkout/bin/omarchy-mac-setup" <<'SETUP'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_SETUP_CALLS"
if [[ ${SETUP_FAIL:-0} == 1 ]]; then exit 42; fi
user=
while (( $# )); do [[ $1 == --user ]] && user=$2 && shift; shift; done
printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$user" >"$TEST_AUTOLOGIN"
SETUP
  printf '#!/bin/bash\n' >"$case_root/checkout/bin/omarchy-system-wait-for-display"
  chmod +x "$case_root/checkout/bin/omarchy-mac-setup" "$case_root/checkout/bin/omarchy-system-wait-for-display"
  printf '[Unit]\nDescription=legacy\n' >"$case_root/system/omarchy-seamless-login.service"
  mkdir -p "$case_root/system/omarchy-seamless-login.service.d"
  printf '[Service]\nExecStartPre=/usr/local/bin/omarchy-wait-for-display\n' >"$case_root/system/omarchy-seamless-login.service.d/wait-for-display.conf"
  printf '[Wayland]\n' >"$case_root/system/10-default.conf"
  sddm_fragment="$case_root/sddm.fragment"
  sddm_alias="$case_root/system/display-manager.service"
  sddm_dropin="$case_root/system/sddm.service.d/wait-for-display.conf"
  seamless_unit="$case_root/system/omarchy-seamless-login.service"
  seamless_dropin_dir="$case_root/system/omarchy-seamless-login.service.d"
  seamless_dropin="$seamless_dropin_dir/require-sddm.conf"
  seamless_wait_dropin="$seamless_dropin_dir/wait-for-display.conf"
  sddm_autologin="$case_root/admin/autologin.conf"
  sddm_system_conf_dir="$case_root/system"
  sddm_admin_conf_dir="$case_root/admin"
  sddm_conf="$case_root/sddm.conf"
  checkout="$case_root/checkout"
  sddm_wayland_session_dir="$case_root/sessions"
  sddm_local_wayland_session_dir="$case_root/sessions"
  seamless_graphical_link="$case_root/graphical.target.wants/omarchy-seamless-login.service"
  seamless_multi_user_link="$case_root/multi-user.target.wants/omarchy-seamless-login.service"
  seamless_default_link="$case_root/default.target.wants/omarchy-seamless-login.service"
  legacy_seamless_helper="$case_root/bin/seamless-login"
  legacy_wait_helper="$case_root/bin/omarchy-wait-for-display"
  legacy_getty_dropin="$case_root/getty@tty1.service.d/autologin.conf"
  legacy_plymouth_dropin="$case_root/plymouth-quit.service.d/wait-for-graphical.conf"
  export TEST_AUTOLOGIN="$sddm_autologin" TEST_SETUP_CALLS="$case_root/setup.calls"
  : >"$TEST_SETUP_CALLS"
  seamless_output=$initial_state
  seamless_status=0
  [[ $initial_state == "enabled" ]] || seamless_status=1
  login_cleanup_only=0
  preserve_autologin=0
  sddm_output=enabled
  sddm_status=0
  reload_count=0
  reload_fail_at=0
  disable_mode=normal
  post_reload_output=
  post_reload_status=1
  printf 'seamless_output=%q\nseamless_status=%q\nsddm_output=%q\nsddm_status=%q\nreload_count=%q\nreload_fail_at=%q\ndisable_mode=%q\npost_reload_output=%q\npost_reload_status=%q\n' \
    "$seamless_output" "$seamless_status" "$sddm_output" "$sddm_status" "$reload_count" "$reload_fail_at" "$disable_mode" "$post_reload_output" "$post_reload_status" >"$case_root/state"
  export STATE_FILE="$case_root/state"
  cat >"$case_root/systemctl" <<'STUB'
#!/bin/bash
set -euo pipefail
source "$STATE_FILE"
write_state() {
  printf 'seamless_output=%q\nseamless_status=%q\nsddm_output=%q\nsddm_status=%q\nreload_count=%q\nreload_fail_at=%q\ndisable_mode=%q\npost_reload_output=%q\npost_reload_status=%q\n' \
    "$seamless_output" "$seamless_status" "$sddm_output" "$sddm_status" "$reload_count" "$reload_fail_at" "$disable_mode" "$post_reload_output" "$post_reload_status" >"$STATE_FILE"
}
case "$1 ${2:-} ${3:-} ${4:-}" in
  "is-enabled sddm.service  ") printf '%s\n' "$sddm_output"; exit "$sddm_status" ;;
  "is-enabled omarchy-seamless-login.service  ") printf '%s\n' "$seamless_output"; exit "$seamless_status" ;;
  "show -p FragmentPath --value") printf '%s\n' "$SDDM_FRAGMENT" ;;
  "daemon-reload   ")
    (( reload_count += 1 ))
    if [[ $reload_count == "$reload_fail_at" && $reload_fail_at != 0 ]]; then write_state; exit 5; fi
    if [[ $reload_count == 3 && -n $post_reload_output ]]; then seamless_output=$post_reload_output; seamless_status=$post_reload_status; fi
    write_state
    ;;
  "disable omarchy-seamless-login.service  ")
    [[ $disable_mode != fail ]] || exit 6
    if [[ $disable_mode != stay ]]; then seamless_output=disabled; seamless_status=1; fi
    write_state
    ;;
  *) printf 'unexpected systemctl call: %s\n' "$*" >&2; exit 7 ;;
esac
STUB
  chmod +x "$case_root/systemctl"
  cat >"$case_root/omarchy-apply-system" <<'SETUP'
#!/bin/bash
if [[ ${SETUP_CREATE_ALIAS:-0} == 1 ]]; then
  mkdir -p "$(dirname "$SDDM_ALIAS")"
  ln -s "$SDDM_FRAGMENT" "$SDDM_ALIAS"
fi
[[ ${SETUP_FAIL:-0} != 1 ]]
SETUP
  printf '#!/bin/bash\nexit 0\n' >"$case_root/omarchy-provision-user"
  printf '#!/bin/bash\nexit 0\n' >"$case_root/omarchy-migrate"
  chmod +x "$case_root/omarchy-apply-system" "$case_root/omarchy-provision-user" "$case_root/omarchy-migrate"
  export SDDM_FRAGMENT="$sddm_fragment"
  export SDDM_ALIAS="$sddm_alias"
  PATH="$case_root:$PATH"
  if [[ $alias_mode == valid ]]; then
    ln -s "$sddm_fragment" "$sddm_alias"
  elif [[ $alias_mode == foreign ]]; then
    printf 'foreign\n' >"$case_root/foreign.fragment"
    ln -s "$case_root/foreign.fragment" "$sddm_alias"
  fi
  if [[ $artifacts == yes ]]; then
    mkdir -p "$(dirname "$seamless_graphical_link")" "$(dirname "$seamless_multi_user_link")" "$(dirname "$seamless_default_link")" "$(dirname "$legacy_seamless_helper")" "$(dirname "$legacy_wait_helper")" "$(dirname "$legacy_getty_dropin")" "$(dirname "$legacy_plymouth_dropin")"
    ln -s "$seamless_unit" "$seamless_graphical_link"
    ln -s "$seamless_unit" "$seamless_multi_user_link"
    ln -s "$seamless_unit" "$seamless_default_link"
    printf 'legacy helper\n' >"$legacy_seamless_helper"
    printf 'legacy wait\n' >"$legacy_wait_helper"
    printf 'legacy getty\n' >"$legacy_getty_dropin"
    printf 'legacy plymouth\n' >"$legacy_plymouth_dropin"
  else
    rm -f "$seamless_unit" "$seamless_wait_dropin"
    rmdir "$seamless_dropin_dir" 2>/dev/null || true
  fi
}

sudo() {
  if [[ $1 == rm && -n ${RM_FAIL_PATH:-} ]]; then
    local rm_args=("$@")
    shift
    while (( $# )); do
      [[ $1 == "$RM_FAIL_PATH" ]] && return 23
      shift
    done
    command "${rm_args[@]}"
    return $?
  fi
  if [[ $1 == env ]]; then
    shift
    while [[ $1 == *=* ]]; do shift; done
    "$@"
  elif [[ $1 == test && $2 == -x && $3 == /usr/bin/omarchy-system-wait-for-display ]]; then
    [[ -x $checkout/bin/omarchy-system-wait-for-display ]]
  else
    "$@"
  fi
}

run_case() {
  local description="$1" callback="$2"
  if (
    set -euo pipefail
    log() { :; }
    eval "$defs"
    fixture "$3" "${4:-yes}" "${5:-valid}"
    state_set() {
      local key="$1" value="$2" temporary="$STATE_FILE.tmp"
      awk -F= -v key="$key" -v value="$value" '$1 == key {$0 = key "=" value} {print}' "$STATE_FILE" >"$temporary"
      mv "$temporary" "$STATE_FILE"
    }
    export checkout sddm_alias sddm_dropin seamless_unit seamless_unit_name seamless_dropin_dir seamless_dropin seamless_wait_dropin sddm_autologin sddm_system_conf_dir sddm_admin_conf_dir sddm_conf sddm_wayland_session_dir sddm_local_wayland_session_dir seamless_graphical_link seamless_multi_user_link seamless_default_link legacy_seamless_helper legacy_wait_helper legacy_getty_dropin legacy_plymouth_dropin
    export -f fail sudo log session_file_path legacy_artifacts_present remove_legacy_login_artifacts
    export -f capture_systemd_state require_enabled_sddm validate_sddm_alias require_sddm_alias inspect_sddm_config inspect_sddm_config_dir validate_sddm_session_dir read_existing_autologin write_root_file install_login_interlock install_sddm_display_guard verify_login_interlock verify_sddm_display_guard prepare_login_transition cleanup_login_transition run_quattro_setup
    "$callback"
  ); then
    pass "$description"
  else
    fail "$description"
  fi
}

case_enabled_fallback() {
  prepare_login_transition
  [[ $preserve_autologin == 1 ]]
  grep -q '^User='"$fixture_user"'$' "$sddm_autologin"
  [[ $(cat "$TEST_SETUP_CALLS") == *"--user $fixture_user"* ]]
  cleanup_login_transition
  [[ ! -e $seamless_unit ]]
  ! legacy_artifacts_present
}

case_fallback_validation() {
  prepare_login_transition
  rm -f "$sddm_autologin"
  if (cleanup_login_transition) 2>/dev/null; then exit 1; fi
}

case_existing_autologin() {
  printf '[Autologin]\nUser=root\nSession=omarchy.desktop\n' >"$sddm_autologin"
  prepare_login_transition
  [[ $preserve_autologin == 1 ]]
  [[ $(cat "$TEST_SETUP_CALLS") == *"--user root"* ]]
  grep -q '^User=root$' "$sddm_autologin"
}

case_bad_autologin() {
  printf '[Autologin]\nUser=root\nSession=missing.desktop\n' >"$sddm_autologin"
  if bash -e -c prepare_login_transition 2>/dev/null; then exit 1; fi
  [[ ! -s $TEST_SETUP_CALLS ]]
  [[ ! -e $seamless_dropin ]]
}

case_cleanup_rerun() {
  prepare_login_transition
  [[ $login_cleanup_only == 1 ]]
  if OMARCHY_LOGIN_TRANSITION_INTERRUPT_AFTER_UNIT=1 bash -e -c cleanup_login_transition 2>/dev/null; then exit 1; fi
  [[ ! -e $seamless_unit && -e $seamless_wait_dropin ]]
  state_set seamless_output not-found
  state_set seamless_status 1
  prepare_login_transition
  cleanup_login_transition
  [[ ! -e $seamless_dropin_dir && ! -e $seamless_graphical_link && ! -e $seamless_multi_user_link && ! -e $seamless_default_link ]]
  [[ ! -e $legacy_seamless_helper && ! -e $legacy_wait_helper && ! -e $legacy_getty_dropin && ! -e $legacy_plymouth_dropin ]]
}

case_bad_alias() {
  if bash -e -c prepare_login_transition 2>/dev/null; then exit 1; fi
  [[ -e $seamless_unit ]]
  [[ ! -e $seamless_dropin ]]
}

case_unknown_state() {
  if bash -e -c prepare_login_transition 2>/dev/null; then exit 1; fi
  [[ ! -e $seamless_dropin ]]
}

case_disable_failure() {
  prepare_login_transition
  disable_mode=fail
  state_set disable_mode fail
  if bash -e -c cleanup_login_transition 2>/dev/null; then exit 1; fi
  [[ -e $seamless_unit ]]
}

case_disable_stays_enabled() {
  prepare_login_transition
  state_set disable_mode stay
  if bash -e -c cleanup_login_transition 2>/dev/null; then exit 1; fi
  [[ -e $seamless_unit ]]
}

case_reload_failure() {
  state_set reload_fail_at 1
  if bash -e -c prepare_login_transition 2>/dev/null; then exit 1; fi
  [[ -e $seamless_unit ]]
}

case_final_state() {
  prepare_login_transition
  state_set post_reload_output enabled
  state_set post_reload_status 0
  if bash -e -c cleanup_login_transition 2>/dev/null; then exit 1; fi
  [[ ! -e $seamless_unit ]]
}

case_final_unknown() {
  prepare_login_transition
  state_set post_reload_output bus-error
  state_set post_reload_status 4
  if bash -e -c cleanup_login_transition 2>/dev/null; then exit 1; fi
  [[ ! -e $seamless_unit ]]
}

case_second_reload_failure() {
  prepare_login_transition
  state_set reload_fail_at 3
  if bash -e -c cleanup_login_transition 2>/dev/null; then exit 1; fi
  [[ ! -e $seamless_unit ]]
}

case_setup_before_alias() {
  prepare_login_transition
  [[ ! -e $sddm_alias && -e $seamless_dropin ]]
  if SETUP_FAIL=1 bash -e -c run_quattro_setup; then exit 1; fi
  [[ ! -e $sddm_alias && -e $seamless_dropin ]]
}

case_setup_after_alias() {
  prepare_login_transition
  if SETUP_CREATE_ALIAS=1 SETUP_FAIL=1 bash -e -c run_quattro_setup; then exit 1; fi
  [[ -e $sddm_alias && -e $seamless_dropin ]]
}

case_alias_enabled_setup_failure() {
  condition_allows_seamless() { [[ ! -e $sddm_alias ]]; }

  prepare_login_transition
  [[ -e $sddm_alias && -e $seamless_dropin ]]
  [[ $(grep -cF 'ConditionPathExists=!/etc/systemd/system/display-manager.service' "$seamless_dropin") == 1 ]]
  if condition_allows_seamless; then exit 1; fi
  if SETUP_FAIL=1 bash -e -c run_quattro_setup; then exit 1; fi
  [[ -e $sddm_alias && $sddm_output == enabled && $sddm_status == 0 ]]
  [[ $login_cleanup_only == 0 ]]
  run_quattro_setup
  cleanup_login_transition
  source "$STATE_FILE"
  [[ $seamless_output == disabled || $seamless_output == not-found ]]
  [[ $seamless_status != 0 ]]
  ! legacy_artifacts_present
}

case_alias_absent_fallback() {
  condition_allows_seamless() { [[ ! -e $sddm_alias ]]; }

  prepare_login_transition
  if ! condition_allows_seamless; then exit 1; fi
  [[ -e $seamless_dropin ]]
  grep -qF 'ConditionPathExists=!/etc/systemd/system/display-manager.service' "$seamless_dropin"
}

cleanup_group_retry() {
  local group_variable="$1" group_path

  fixture enabled yes valid
  group_path=${!group_variable}
  prepare_login_transition
  if RM_FAIL_PATH="$group_path" bash -e -c cleanup_login_transition; then exit 1; fi
  if [[ ! -e $group_path && ! -L $group_path ]]; then printf 'missing failed group path: %s\n' "$group_path" >&2; return 1; fi
  state_set seamless_output disabled
  state_set seamless_status 1
  prepare_login_transition
  cleanup_login_transition
  if legacy_artifacts_present; then printf 'legacy artifacts remain after retry: %s\n' "$group_path" >&2; return 1; fi
}

case_cleanup_groups() {
  cleanup_group_retry seamless_dropin
  cleanup_group_retry seamless_graphical_link
  cleanup_group_retry legacy_seamless_helper
  cleanup_group_retry legacy_getty_dropin
}

case_unit_removal_failure() {
  prepare_login_transition
  if RM_FAIL_PATH="$seamless_unit" bash -e -c cleanup_login_transition; then exit 1; fi
  [[ -e $seamless_unit ]] || exit 1
  state_set seamless_output disabled
  state_set seamless_status 1
  prepare_login_transition
  cleanup_login_transition
  [[ ! -e $seamless_unit ]]
}

case_migration_completed() {
  rm -f "$seamless_unit"
  rmdir "$seamless_dropin_dir" 2>/dev/null || true
  seamless_output=not-found
  state_set seamless_output not-found
  state_set seamless_status 1
  prepare_login_transition
  grep -qF 'ExecStartPre=/usr/bin/omarchy-system-wait-for-display' "$sddm_dropin"
}

case_migration_actual() {
  local migration_root migration_unit migration_dropin migration_systemctl

  migration_root="$case_root/migration"
  migration_unit="$migration_root/omarchy-seamless-login.service"
  migration_dropin="$migration_root/omarchy-seamless-login.service.d"
  migration_systemctl="$migration_root/systemctl"
  mkdir -p "$migration_root"
  printf '[Unit]\nDescription=legacy\n' >"$migration_unit"
  printf '#!/bin/bash\nprintf reload >>"%s"\n' "$migration_root/reloads" >"$migration_systemctl"
  chmod +x "$migration_systemctl"
  printf '#!/bin/bash\nexit 0\n' >"$migration_root/modinfo"
  chmod +x "$migration_root/modinfo"
  (
    export OMARCHY_MIGRATION_SEAMLESS_UNIT="$migration_unit"
    export OMARCHY_MIGRATION_SEAMLESS_DROPIN_DIR="$migration_dropin"
    export PATH="$migration_root:$PATH"
    sudo() { "$@"; }
    export -f sudo
    bash -euo pipefail "$migration"
  )
  grep -qF 'ExecStartPre=/usr/bin/omarchy-system-wait-for-display' "$migration_dropin/wait-for-display.conf"
  [[ -s "$migration_root/reloads" ]]
}

run_case "enabled seamless derives USER and final autologin validation" case_enabled_fallback enabled yes valid
run_case "fallback autologin loss fails final validation" case_fallback_validation enabled yes valid
run_case "valid existing autologin User is preserved" case_existing_autologin enabled yes valid
run_case "malformed or missing session fails before setup" case_bad_autologin enabled yes valid
run_case "disabled cleanup resumes after interruption" case_cleanup_rerun disabled yes valid
run_case "foreign alias blocks cleanup-pending state" case_bad_alias disabled yes foreign
run_case "missing alias blocks cleanup-pending state" case_bad_alias disabled yes missing
run_case "unknown seamless state fails closed" case_unknown_state bus-error yes valid
run_case "disable operational failure leaves unit" case_disable_failure enabled yes valid
run_case "post-disable still-enabled state leaves unit" case_disable_stays_enabled enabled yes valid
run_case "first daemon-reload failure is fatal" case_reload_failure enabled yes valid
run_case "second daemon-reload failure is fatal" case_second_reload_failure enabled yes valid
run_case "final re-enabled state fails after cleanup" case_final_state enabled yes valid
run_case "final unknown state fails after cleanup" case_final_unknown enabled yes valid
run_case "setup failure before alias leaves fallback interlocked" case_setup_before_alias enabled yes missing
run_case "setup failure after alias leaves interlock selected" case_setup_after_alias enabled yes missing
run_case "valid alias and enabled seamless recover setup failure after interlock" case_alias_enabled_setup_failure enabled yes valid
run_case "absent alias leaves seamless fallback condition available" case_alias_absent_fallback enabled yes missing
run_case "cleanup groups fail visibly and converge on retry" case_cleanup_groups enabled yes valid
run_case "successful disable with unit-removal failure is resumable" case_unit_removal_failure enabled yes valid
run_case "completed migration still gets the SDDM display guard" case_migration_completed not-found no valid
run_case "migration executes against a safe fixture and installs the shared guard" case_migration_actual not-found no valid
