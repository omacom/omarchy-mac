#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_path="$test_tmp/pkg-add-bin"
mkdir -p "$mock_path"

# pacman -Si accepts repo-qualified names and -Q only bare ones, as the real
# one does. dropbox is known only through the Usage = Sync omarchy repository.
cat >"$mock_path/pacman" <<'EOF_PACMAN'
#!/bin/bash
case "$1" in
  -Q) [[ " $(<"$TEST_TMP/installed") " == *" $2 "* ]] ;;
  -Si) [[ $2 == "omarchy/dropbox" || $2 == "python-gpgme" ]] ;;
  -S) shift; printf '%s\n' "$*" >"$TEST_TMP/pkg-add-command"; printf ' %s' "${@##*/}" >>"$TEST_TMP/installed" ;;
  *) exit 1 ;;
esac
EOF_PACMAN

cat >"$mock_path/sudo" <<'EOF_SUDO'
#!/bin/bash
"$@"
EOF_SUDO

chmod +x "$mock_path/pacman" "$mock_path/sudo"
run_pkg_add() {
  PATH="$ROOT/bin:$mock_path:$PATH" TEST_TMP="$test_tmp" "$ROOT/bin/omarchy-pkg-add" "$@"
}

: >"$test_tmp/installed"
run_pkg_add omarchy/dropbox python-gpgme 2>"$test_tmp/errors" || fail "repo-qualified package installs" "$(<"$test_tmp/errors")"
[[ $(<"$test_tmp/pkg-add-command") == "--noconfirm --needed omarchy/dropbox python-gpgme" ]] ||
  fail "repo-qualified target reaches pacman unchanged" "$(<"$test_tmp/pkg-add-command")"
pass "repo-qualified targets install and verify by package name"

rm -f "$test_tmp/pkg-add-command"
run_pkg_add omarchy/dropbox || fail "installed repo-qualified package is accepted"
[[ ! -e $test_tmp/pkg-add-command ]] || fail "installed repo-qualified package is not reinstalled"
pass "installed repo-qualified targets are recognized"
