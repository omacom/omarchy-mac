#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
ln -s /usr/bin/dirname "$work/bin/dirname"
cat >"$work/bin/pacman" <<'SH'
#!/bin/bash
case $1 in
  -Q) [[ -e $TEST_INSTALLED ]] ;;
  -S)
    printf 'repo\n' >>"$TEST_LOG"
    [[ $TEST_REPO != failed ]] || exit 5
    [[ $TEST_REPO != silent ]] || exit 0
    : >"$TEST_INSTALLED"
    printf '#!/bin/bash\nexit 0\n' >"$TEST_BIN/obsidian"
    /usr/bin/chmod +x "$TEST_BIN/obsidian"
    ;;
  *) exit 99 ;;
esac
SH
cat >"$work/bin/yay" <<'SH'
#!/bin/bash
printf 'aur\n' >>"$TEST_LOG"
[[ $TEST_AUR != failed ]] || exit 6
: >"$TEST_INSTALLED"
printf '#!/bin/bash\nexit 0\n' >"$TEST_BIN/obsidian"
/usr/bin/chmod +x "$TEST_BIN/obsidian"
SH
cat >"$work/bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
chmod +x "$work/bin/pacman" "$work/bin/yay" "$work/bin/sudo"
export TEST_BIN="$work/bin" TEST_INSTALLED="$work/installed" TEST_LOG="$work/calls"

# Use the real leaf, command-presence detector and both package helpers.
# PATH intentionally excludes installed desktop apps and package managers.
run_leaf() {
  OMARCHY_UNAME_M="$1" TEST_REPO="$2" TEST_AUR="$3" PATH="$work/bin:$ROOT/bin" \
    /bin/bash -eEuo pipefail -c 'source "$1"' _ "$ROOT/install/user/hardware/apple/obsidian.sh" >"$work/output" 2>&1
}
for repo in failed silent; do
  rm -f "$TEST_INSTALLED" "$TEST_BIN/obsidian" "$TEST_LOG"
  run_leaf aarch64 "$repo" success || fail "strict provisioning reaches AUR after $repo repository installation" "$(cat "$work/output")"
  [[ $(cat "$TEST_LOG") == $'repo\naur' && -x $TEST_BIN/obsidian ]] || fail "the AUR fallback registers Obsidian after $repo repo installation"
done
pass "the real optional leaf reaches its AUR fallback after repository failure or false success under bash -eE"

rm -f "$TEST_INSTALLED" "$TEST_BIN/obsidian" "$TEST_LOG"
run_leaf arm64 success failed || fail "successful repository installation needs no AUR build"
[[ $(cat "$TEST_LOG") == repo && -x $TEST_BIN/obsidian ]] || fail "repository success skips the AUR fallback"
rm "$TEST_LOG"
run_leaf aarch64 failed failed || fail "an existing Obsidian command is left alone"
[[ ! -e $TEST_LOG ]] || fail "an existing command triggers no package operation"
pass "repository success and an existing registered command avoid unnecessary AUR work"

rm -f "$TEST_INSTALLED" "$TEST_BIN/obsidian" "$TEST_LOG"
run_leaf aarch64 failed failed || fail "this optional leaf preserves provisioning when both sources fail"
[[ $(cat "$TEST_LOG") == $'repo\naur' ]] || fail "both sources are attempted in order"
grep -q 'Warning: obsidian-appimage failed to build' "$work/output" || fail "a failed optional AUR install remains visible"
rm "$TEST_LOG"
run_leaf x86_64 failed failed || fail "the ARM substitution skips x86"
[[ ! -e $TEST_LOG ]] || fail "x86 receives no ARM substitution"
pass "optional failure warns without aborting provisioning, and x86 stays outside the ARM substitution"
