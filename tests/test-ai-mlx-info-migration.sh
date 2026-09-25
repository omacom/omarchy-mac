#!/bin/bash
# Exercise migration failures in disposable homes, using the real runner flags.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="$ROOT/migrations/1789233600.sh"

pass() { echo "✓ $*"; }
fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "=== MLX info migration ==="
echo "Migration: $MIGRATION"

[[ -f $MIGRATION ]] || fail "the migration is missing"
bash -n "$MIGRATION" || fail "the migration does not parse"
pass "the migration is present and parses"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

out="$work/out"

# Runs the migration the way omarchy-migrate does. The second argument is an
# optional directory prepended to PATH (for stubs). Echoes the exit status;
# combined output lands in $out.
run_migration() {
  local home="$1" path_dir="${2:-}" status=0
  if [[ -n $path_dir ]]; then
    HOME="$home" PATH="$path_dir:$PATH" \
      bash -euo pipefail "$MIGRATION" >"$out" 2>&1 || status=$?
  else
    HOME="$home" \
      bash -euo pipefail "$MIGRATION" >"$out" 2>&1 || status=$?
  fi
  echo "$status"
}

# A healthy venv: a reporter that echoes its arguments, and an mlx-omarchy
# runner that answers with the reporter path, as `mlx-omarchy -I -c ...`
# does for a working install.
make_healthy_venv() {
  local home="$1" bin="$1/.local/bin" reporter
  mkdir -p "$bin"
  reporter="$home/.local/share/mlx-omarchy/venv/bin/mlx-omarchy-info"
  mkdir -p -- "$(dirname -- "$reporter")"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*"\n' >"$reporter"
  chmod 0755 "$reporter"
  printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$reporter" >"$bin/mlx-omarchy"
  chmod 0755 "$bin/mlx-omarchy"
}

assert_no_shim() {
  if [[ -e "$1/mlx-omarchy-info" || -L "$1/mlx-omarchy-info" ]]; then
    fail "$1/mlx-omarchy-info must not exist after this case"
  fi
}

assert_no_temps() {
  local leftover
  leftover=$(find "$1" -maxdepth 1 -name '.mlx-omarchy-info.*' -print -quit)
  [[ -z $leftover ]] || fail "leftover temp file: $leftover"
}

assert_skip_message() {
  grep -q '^Skipping:' "$out" ||
    fail "the migration must explain the skip on stderr, got: $(cat "$out")"
}

echo
echo "=== a broken MLX runner skips without writing anything ==="

home="$work/broken"
bin="$home/.local/bin"
mkdir -p "$bin"
printf '#!/bin/bash\necho "ModuleNotFoundError: No module named mlx" >&2\nexit 1\n' \
  >"$bin/mlx-omarchy"
chmod 0755 "$bin/mlx-omarchy"

status=$(run_migration "$home")
[[ $status == 0 ]] || fail "a broken venv must not block the migration chain (exit $status)"
assert_no_shim "$bin"
assert_no_temps "$bin"
assert_skip_message
pass "broken runner: exit 0, nothing installed, skip reported"

echo
echo "=== a reporter that cannot be exec'd skips ==="

# The venv answers, but with a target the shim must not wrap: a path that
# does not exist, one that lost its +x bit, and empty output.
for kind in missing not-executable empty; do
  home="$work/bad-reporter-$kind"
  bin="$home/.local/bin"
  mkdir -p "$bin"
  case $kind in
    missing) target="$home/.local/share/mlx-omarchy/venv/bin/mlx-omarchy-info" ;;
    not-executable)
      target="$home/.local/share/mlx-omarchy/venv/bin/mlx-omarchy-info"
      mkdir -p -- "$(dirname -- "$target")"
      printf '#!/bin/bash\n' >"$target"
      chmod 0644 "$target"
      ;;
    empty) target="" ;;
  esac
  if [[ -n $target ]]; then
    printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$target" >"$bin/mlx-omarchy"
  else
    printf '#!/bin/bash\nexit 0\n' >"$bin/mlx-omarchy"
  fi
  chmod 0755 "$bin/mlx-omarchy"

  status=$(run_migration "$home")
  [[ $status == 0 ]] || fail "$kind reporter: migration must still skip cleanly (exit $status)"
  assert_no_shim "$bin"
  assert_no_temps "$bin"
  assert_skip_message
done
pass "missing, not-executable and empty reporter targets all skip"

echo
echo "=== a healthy venv installs a shim that forwards arguments ==="

home="$work/healthy"
bin="$home/.local/bin"
make_healthy_venv "$home"

status=$(run_migration "$home")
[[ $status == 0 ]] || fail "a healthy venv must install the shim (exit $status)"
[[ -x $bin/mlx-omarchy-info ]] || fail "the shim was not installed executable"
forwarded=$("$bin/mlx-omarchy-info" --flag value)
[[ $forwarded == "--flag value" ]] ||
  fail "the shim must forward arguments to the reporter, got: $forwarded"
assert_no_temps "$bin"
pass "shim installed executable and forwards its arguments"

echo
echo "=== no MLX runner means nothing to do ==="

home="$work/absent"
bin="$home/.local/bin"
mkdir -p "$bin"

status=$(run_migration "$home")
[[ $status == 0 ]] || fail "absent MLX must not block the chain (exit $status)"
assert_no_shim "$bin"
if grep -q '^Skipping:' "$out"; then
  fail "absent MLX is not a failure; the migration must stay silent"
fi
pass "absent MLX: silent no-op"

echo
echo "=== reruns are idempotent and never overwrite an existing shim ==="

home="$work/idempotent"
bin="$home/.local/bin"
make_healthy_venv "$home"

status=$(run_migration "$home")
[[ $status == 0 ]] || fail "first run must succeed (exit $status)"
installed=$(cat "$bin/mlx-omarchy-info")

# A second run with the shim already in place must leave it byte-identical.
status=$(run_migration "$home")
[[ $status == 0 ]] || fail "second run must succeed (exit $status)"
[[ $(cat "$bin/mlx-omarchy-info") == "$installed" ]] ||
  fail "the second run rewrote the installed shim"

# A pre-existing file at the target — e.g. the user's own venv installed one —
# must be preserved even when it is something else entirely.
printf '#!/bin/bash\necho custom\n' >"$bin/mlx-omarchy-info"
status=$(run_migration "$home")
[[ $status == 0 ]] || fail "a pre-existing shim must not fail the run (exit $status)"
grep -q 'echo custom' "$bin/mlx-omarchy-info" ||
  fail "the migration overwrote a pre-existing file"
assert_no_temps "$bin"
pass "idempotent rerun, pre-existing file preserved"

echo
echo "=== a fixed venv succeeds on the next run ==="

home="$work/retry"
bin="$home/.local/bin"
mkdir -p "$bin"
printf '#!/bin/bash\nexit 1\n' >"$bin/mlx-omarchy"
chmod 0755 "$bin/mlx-omarchy"

status=$(run_migration "$home")
[[ $status == 0 ]] || fail "broken run must not block the chain (exit $status)"
assert_no_shim "$bin"

# The venv heals (recreated after a Python bump); rerunning the migration
# must now install a working shim.
make_healthy_venv "$home"
status=$(run_migration "$home")
[[ $status == 0 ]] || fail "healed venv must install on retry (exit $status)"
forwarded=$("$bin/mlx-omarchy-info" --flag value)
[[ $forwarded == "--flag value" ]] ||
  fail "the retried shim must forward arguments, got: $forwarded"
pass "retry after failure installs a working shim"

echo
echo "=== a failure after the temp file exists cleans it up ==="

# A failing chmod after the temp shim is written must leave neither a shim
# nor a stray temp file behind. The original code sailed straight past the
# failure and moved the temp into place anyway.
home="$work/cleanup"
bin="$home/.local/bin"
stub_dir="$work/stubs"
mkdir -p "$bin" "$stub_dir"
printf '#!/bin/bash\nexit 1\n' >"$stub_dir/chmod"
chmod 0755 "$stub_dir/chmod"
make_healthy_venv "$home"

status=$(run_migration "$home" "$stub_dir")
[[ $status == 0 ]] || fail "a failed chmod must not block the chain (exit $status)"
assert_no_shim "$bin"
assert_no_temps "$bin"
assert_skip_message
pass "failed chmod: skip reported, no shim, temp cleaned up"

echo
echo "=== a failed temporary-file creation skips without blocking ==="

home="$work/readonly"
bin="$home/.local/bin"
make_healthy_venv "$home"
printf '#!/bin/bash\nexit 1\n' >"$stub_dir/mktemp"
chmod 0755 "$stub_dir/mktemp"

status=$(run_migration "$home" "$stub_dir")
[[ $status == 0 ]] || fail "failed mktemp must not block the chain (exit $status)"
assert_no_shim "$bin"
assert_no_temps "$bin"
assert_skip_message
pass "failed mktemp: skip reported, chain continues"

echo
echo "All MLX info migration checks passed."
