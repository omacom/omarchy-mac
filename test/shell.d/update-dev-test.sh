#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
git_log="$test_tmp/git.log"
checkout="$test_tmp/checkout"
mkdir -p "$stub_bin" "$checkout"

cat >"$stub_bin/git" <<'SH'
#!/bin/bash

printf '%s\n' "$*" >>"$TEST_GIT_LOG"

[[ $1 == "-C" ]] || exit 1
shift 2

case "$1" in
  rev-parse)
    case "$2" in
      --is-inside-work-tree)
        [[ ${TEST_GIT_CHECKOUT:-yes} == "yes" ]] || exit 1
        echo true
        ;;
      --abbrev-ref)
        [[ ${TEST_GIT_UPSTREAM:-origin/quattro} != "none" ]] || exit 1
        echo "${TEST_GIT_UPSTREAM:-origin/quattro}"
        ;;
      --verify)
        [[ ${TEST_GIT_UPSTREAM:-origin/quattro} != "none" ]] || exit 1
        ;;
      --git-path)
        if [[ $3 == "rebase-merge" && ${TEST_GIT_REBASE_FAIL:-no} == "yes" ]]; then
          printf '%s\n' "$TEST_GIT_REBASE_DIR"
        else
          printf '%s\n' "${TEST_GIT_REBASE_DIR}-missing"
        fi
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  pull)
    [[ $2 == "--ff-only" ]] || exit 1
    if [[ ${TEST_GIT_PULL_FAIL:-no} == "yes" ]]; then
      exit 1
    fi
    exit 0
    ;;
  rebase)
    if [[ $2 == "--abort" ]]; then
      exit 0
    fi
    [[ $2 == "--autostash" && $3 == '@{upstream}' ]] || exit 1
    if [[ ${TEST_GIT_REBASE_FAIL:-no} == "yes" ]]; then
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$stub_bin/git"

run_dev_update() {
  OMARCHY_PATH="$1" \
    TEST_GIT_LOG="$git_log" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-update-dev"
}

: >"$git_log"
run_dev_update /usr/share/omarchy
[[ ! -s $git_log ]] || fail "package-backed updates do not invoke git" "$(cat "$git_log")"
pass "package-backed updates skip the dev checkout step"

: >"$git_log"
run_dev_update "$checkout"
grep -Fx -- "-C $checkout pull --ff-only" "$git_log" >/dev/null ||
  fail "dev checkout update pulls its upstream with fast-forward only" "$(cat "$git_log")"
if grep -q ' rebase ' "$git_log"; then
  fail "a fast-forward does not rebase" "$(cat "$git_log")"
fi
pass "dev checkout update pulls its configured upstream"

: >"$git_log"
if ! TEST_GIT_PULL_FAIL=yes run_dev_update "$checkout" >"$test_tmp/diverged.out" 2>"$test_tmp/diverged.err"; then
  fail "a dev checkout that cannot fast-forward still lets the update continue" "$(cat "$test_tmp/diverged.err")"
fi
grep -Fx -- "-C $checkout rebase --autostash @{upstream}" "$git_log" >/dev/null ||
  fail "a dev checkout that cannot fast-forward rebases onto its upstream" "$(cat "$git_log")"
pass "a dev checkout that cannot fast-forward rebases local commits onto upstream"

rebase_dir="$test_tmp/rebase-merge"
mkdir -p "$rebase_dir"
: >"$git_log"
if ! TEST_GIT_PULL_FAIL=yes TEST_GIT_REBASE_FAIL=yes TEST_GIT_REBASE_DIR="$rebase_dir" \
  run_dev_update "$checkout" >"$test_tmp/rebase.out" 2>"$test_tmp/rebase.err"; then
  fail "a conflicted dev checkout rebase still lets the update continue" "$(cat "$test_tmp/rebase.err")"
fi
grep -Fx -- "-C $checkout rebase --abort" "$git_log" >/dev/null ||
  fail "a conflicted dev checkout rebase is aborted" "$(cat "$git_log")"
grep -F "was aborted. Local commits were kept." "$test_tmp/rebase.err" >/dev/null ||
  fail "a conflicted dev checkout rebase reports that local commits were kept" "$(cat "$test_tmp/rebase.err")"
pass "a conflicted dev checkout rebase aborts and keeps local commits"

: >"$git_log"
TEST_GIT_UPSTREAM=none run_dev_update "$checkout"
if grep -q ' pull ' "$git_log"; then
  fail "dev checkout without an upstream is not pulled" "$(cat "$git_log")"
fi
pass "dev checkout without an upstream is skipped safely"

: >"$git_log"
if TEST_GIT_CHECKOUT=no run_dev_update "$checkout" >"$test_tmp/invalid.out" 2>"$test_tmp/invalid.err"; then
  fail "invalid dev checkout fails the update"
fi
grep -F "OMARCHY_PATH is not a git checkout: $checkout" "$test_tmp/invalid.err" >/dev/null ||
  fail "invalid dev checkout reports the configured path" "$(cat "$test_tmp/invalid.err")"
pass "invalid dev checkout fails with a useful error"

grep -qE '^ *omarchy-update-dev$' "$ROOT/bin/omarchy-update" ||
  fail "top-level update includes the dev checkout step"
pass "top-level update includes the dev checkout step"
