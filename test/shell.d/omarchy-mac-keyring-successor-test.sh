#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export TEST_CALLS="$test_tmp/calls"
new_key=FBD6874D423C418DDB6D143EECE19CDDE306DBD2
export TEST_NEW_KEY="$new_key"
mkdir -p "$test_tmp/source/migrations"
for name in 1789316115 1789407944; do
  cp "$ROOT/migrations/$name.sh" "$test_tmp/source/migrations/"
done
pacman() {
  [[ $* == '-Q omarchy-mac-keyring' ]] || return 99
  [[ ${TEST_VERSION:-20260914-2} != missing ]] || return 1
  printf 'omarchy-mac-keyring %s\n' "${TEST_VERSION:-20260914-2}"
}
sudo() {
  printf '%s\n' "$*" >>"$TEST_CALLS"
  case "$*" in
    'pacman-key --populate omarchy-mac') return "${TEST_POPULATE_FAILURE:-0}" ;;
    "pacman-key --finger $TEST_NEW_KEY")
      [[ ${TEST_MISSING_KEY:-0} == 0 ]] || return 1
      printf '%s\n' "$TEST_NEW_KEY" ;;
    *) return 99 ;;
  esac
}
omarchy-notification-dismiss() { :; }
export -f pacman sudo omarchy-notification-dismiss

for scenario in current newer missing older populate fingerprint; do
  markers="$test_tmp/$scenario"
  mkdir "$markers"
  # Obsolete development markers must not prevent the retained successor.
  # This models marker handling only, not installing unsigned RC4 under strict policy.
  touch "$markers/1789316115.sh" "$markers/1789317000.sh" "$markers/1789390468.sh"
  export TEST_VERSION=20260914-2 TEST_POPULATE_FAILURE=0 TEST_MISSING_KEY=0
  case "$scenario" in
    newer) TEST_VERSION=20260915-1 ;;
    missing) TEST_VERSION=missing ;;
    older) TEST_VERSION=20260914-1 ;;
    populate) TEST_POPULATE_FAILURE=1 ;;
    fingerprint) TEST_MISSING_KEY=1 ;;
  esac
  : >"$TEST_CALLS"
  if OMARCHY_PATH="$test_tmp/source" OMARCHY_MIGRATION_STATE="$markers" bash "$ROOT/bin/omarchy-migrate" >"$test_tmp/result" 2>&1; then
    [[ $scenario == current || $scenario == newer ]] || fail "$scenario accepted"
    [[ -f $markers/1789407944.sh ]] || fail 'successor marker missing'
    [[ $(cat "$TEST_CALLS") == "pacman-key --populate omarchy-mac"$'\n'"pacman-key --finger $new_key" ]] || fail 'unexpected trust operations'
    : >"$TEST_CALLS"
    OMARCHY_PATH="$test_tmp/source" OMARCHY_MIGRATION_STATE="$markers" bash "$ROOT/bin/omarchy-migrate" >/dev/null
    [[ ! -s $TEST_CALLS ]] || fail 'completed successor ran twice'
  else
    [[ $scenario != current && $scenario != newer ]] || fail "$scenario failed" "$(cat "$test_tmp/result")"
    [[ ! -f $markers/1789407944.sh ]] || fail 'failed successor marked complete'
    case "$scenario" in
      older) expected_error='20260914-2 or newer is required' ;;
      missing) expected_error='Install the reviewed Omarchy Mac keyring package first' ;;
      populate) expected_error='Could not populate Omarchy Mac signing trust' ;;
      fingerprint) expected_error='is missing after keyring population' ;;
    esac
    grep -qF "$expected_error" "$test_tmp/result" || fail "$scenario has no useful diagnostic"
    if grep -qF 'can only `return' "$test_tmp/result"; then fail 'top-level return error'; fi
    if [[ $scenario == older || $scenario == missing ]]; then
      [[ ! -s $TEST_CALLS ]] || fail 'rejected package still touched trust'
    fi
  fi
done
pass 'successor repairs completed migrations, requires current package and remains pending on failure'
