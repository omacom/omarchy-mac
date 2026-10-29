#!/bin/bash
#
# The shell's Qt 6.11 load patch only works on Omarchy's Quickshell build. The
# migration must install omarchy/quickshell over Arch's build or a leftover
# quickshell-git, leave Omarchy's build alone, and skip cleanly when [omarchy]
# cannot serve it. The shell must keep the pragma the build looks for.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

migration="$ROOT/migrations/1792350611.sh"
[[ -f $migration ]] || fail "Omarchy quickshell migration exists"

[[ $(head -1 "$ROOT/shell/shell.qml") == "//@ pragma OmarchyLoadPatch" ]] ||
  fail "shell.qml opens with the OmarchyLoadPatch pragma"
pass "the shell asks Omarchy's Quickshell build for the Qt 6.11 load patch"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

stub_bin="$test_dir/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/quickshell" <<'STUB'
#!/bin/bash
[[ $1 == --version ]] || exit 1
printf 'Quickshell 0.3.2 (revision , distributed by %s)\n' "${STUB_DISTRIBUTOR:?}"
STUB

cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
if [[ $1 == -Si ]]; then
  [[ $2 == omarchy/quickshell && ${STUB_AVAILABLE:-1} == 1 ]]
  exit
fi
echo "$@" >>"${PACMAN_CALLS:?}"
STUB

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB

chmod +x "$stub_bin"/*

run_migration() {
  : >"$test_dir/calls"
  PATH="$stub_bin:$PATH" PACMAN_CALLS="$test_dir/calls" bash -euo pipefail "$migration" >/dev/null 2>&1
}

STUB_DISTRIBUTOR="Omarchy" run_migration || fail "migration succeeds on Omarchy's build"
[[ ! -s $test_dir/calls ]] || fail "Omarchy's build is left alone" "$(cat "$test_dir/calls")"
pass "migration is a no-op on Omarchy's build"

STUB_DISTRIBUTOR="Arch Linux" run_migration || fail "migration succeeds on Arch's build"
[[ $(cat "$test_dir/calls") == "-S --noconfirm --ask 4 omarchy/quickshell" ]] ||
  fail "Arch's build is replaced from [omarchy]" "$(cat "$test_dir/calls")"
pass "migration replaces Arch's build, or a conflicting quickshell-git, from [omarchy]"

STUB_DISTRIBUTOR="Arch Linux" STUB_AVAILABLE=0 run_migration ||
  fail "migration skips instead of failing when [omarchy] cannot serve the package"
[[ ! -s $test_dir/calls ]] || fail "nothing is installed without [omarchy]" "$(cat "$test_dir/calls")"
pass "migration skips cleanly when [omarchy] cannot serve the package"
