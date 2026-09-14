#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
fixture="$test_tmp/omarchy"
mkdir -p "$fixture/bin" "$fixture/install/user" "$fixture/install/helpers" "$fixture/migrations" "$fixture/default/agents"
cp "$ROOT/install/user/all.sh" "$ROOT/install/user/hermes.sh" "$fixture/install/user/"
cp "$ROOT/migrations/1787760281.sh" "$fixture/migrations/"
ln -s "$ROOT/default/agents/skills" "$fixture/default/agents/skills"
for command in omarchy-install-hermes-cli omarchy-done; do
  ln -s "$ROOT/bin/$command" "$fixture/bin/$command"
done

# Run the real user-stage driver and provisioner. Every unrelated leaf is
# intercepted at run_logged so it cannot reconfigure the active desktop.
cat >"$fixture/install/helpers/logging.sh" <<'SH'
run_logged() {
  if [[ $1 == "$OMARCHY_INSTALL/user/hermes.sh" ]]; then
    bash -eE -c 'source "$1"' bash "$1"
  fi
}
SH
for command in xdg-user-dirs-update xdg-settings xdg-mime omarchy-refresh-applications; do
  printf '#!/bin/bash\nexit 0\n' >"$fixture/bin/$command"
  chmod +x "$fixture/bin/$command"
done
cat >"$fixture/bin/omarchy-pkg-present" <<'SH'
#!/bin/bash
[[ $* == hermes-desktop && ${TEST_HERMES_DESKTOP:-0} == 1 ]]
SH
cat >"$fixture/bin/mise" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_MISE_CALLS"
[[ $1 != where ]]
SH
chmod +x "$fixture/bin/omarchy-pkg-present" "$fixture/bin/mise"

export TEST_MISE_CALLS="$test_tmp/mise.calls"
marker='# Written by omarchy-install-hermes-cli.'
run_first_install() {
  HOME="$task_home" OMARCHY_PATH="$fixture" OMARCHY_INSTALL="$fixture/install" \
    OMARCHY_INSTALL_LOG_FILE="$test_tmp/provision.log" PATH="$fixture/bin:$PATH" \
    bash "$ROOT/bin/omarchy-provision-user" --first-install >"$test_tmp/provision.output" 2>&1
}
prepare_user() {
  task_home="$test_tmp/$1"
  wrapper="$task_home/.local/bin/hermes"
  mkdir -p "$task_home/.local/bin" "$task_home/.local/state/omarchy"
  : >"$TEST_MISE_CALLS"
}
assert_finalized() {
  [[ -f $task_home/.local/state/omarchy/migrations/1787760281.sh ]] || fail "first install marks the Hermes migration complete"
  [[ -f $task_home/.local/state/omarchy/done/finalize-user ]] || fail "user finalization completes"
}

prepare_user fresh
run_first_install || fail "fresh user provisioning succeeds" "$(cat "$test_tmp/provision.output")"
assert_finalized
[[ -x $wrapper ]] && grep -qxF "$marker" "$wrapper" || fail "fresh install seeds the Hermes wrapper before migrations are marked"
! grep -Eq '^(use|install|uninstall|rm) ' "$TEST_MISE_CALLS" || fail "fresh seeding remains lazy"
cp "$wrapper" "$test_tmp/expected-wrapper"
run_first_install || fail "repeat first-install setup succeeds"
cmp "$wrapper" "$test_tmp/expected-wrapper" || fail "repeat setup preserves the lazy wrapper"
pass "real first-install provisioning seeds Hermes before marking migrations complete"

prepare_user opted-out
touch "$task_home/.local/state/omarchy/preinstalls-removed"
run_first_install || fail "preinstall opt-out does not block finalization"
assert_finalized
[[ ! -e $wrapper && ! -s $TEST_MISE_CALLS ]] || fail "fresh setup respects the preinstall opt-out"
pass "user provisioning preserves preinstall opt-out"

for kind in executable nonexecutable dangling-link directory; do
  prepare_user "foreign-$kind"
  case "$kind" in
    executable | nonexecutable)
      printf '#!/bin/bash\ntouch "%s"\n' "$task_home/foreign-ran" >"$wrapper"
      [[ $kind != executable ]] || chmod +x "$wrapper"
      cp -p "$wrapper" "$task_home/expected"
      ;;
    dangling-link) ln -s "$task_home/missing" "$wrapper" ;;
    directory) mkdir "$wrapper" ;;
  esac
  run_first_install || fail "foreign $kind does not block finalization"
  assert_finalized
  [[ ! -e $task_home/foreign-ran && ! -s $TEST_MISE_CALLS ]] || fail "foreign $kind is not executed or managed with mise"
  case "$kind" in
    executable | nonexecutable)
      cmp "$wrapper" "$task_home/expected" || fail "foreign $kind content is preserved"
      [[ $(stat -c %a "$wrapper") == "$(stat -c %a "$task_home/expected")" ]] || fail "foreign $kind permissions are preserved"
      ;;
    dangling-link) [[ -L $wrapper && $(readlink "$wrapper") == "$task_home/missing" ]] || fail "foreign dangling link is preserved" ;;
    directory) [[ -d $wrapper ]] || fail "foreign directory is preserved" ;;
  esac
done
pass "fresh setup preserves user-owned Hermes paths without executing them"

prepare_user desktop
TEST_HERMES_DESKTOP=1 run_first_install || fail "unbootstrapped Hermes Desktop does not block user setup"
assert_finalized
[[ ! -e $wrapper ]] || fail "desktop ownership prevents a second Hermes launcher"
pass "first-install finalization completes while Hermes Desktop awaits its own setup"
