#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

migration="$ROOT/migrations/1788782695.sh"

[[ -f $migration ]] || fail "the unpackaged-units repair migration ships"
[[ ! -x $migration ]] || fail "migration files are 0644, not executable"
head -1 "$migration" | grep -q '^echo ' || fail "the migration starts with an echo description"
pass "the unpackaged-units repair migration ships in migration format"

# The production literals: migration 1788139121 wrote exactly this link name
# pointing at exactly this absolute target, and only that pair may be removed.
grep -Fq 'graphical-session.target.wants/omarchy-brightness-keyboard-auto.service' "$migration" ||
  fail "the migration names the exact historical link path"
grep -Fq '/usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service' "$migration" ||
  fail "the migration names the exact historical link target"
pass "the migration names the exact legacy link and target"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
fake_home="$TMPDIR/home"
wants_dir="$fake_home/.config/systemd/user/graphical-session.target.wants"
mkdir -p "$wants_dir"

# Whether this host installed the real unit must not decide the outcome, so
# behavior runs against a sandboxed copy whose historical target is redirected
# to a guaranteed-missing path. The production literal itself is asserted above
# and by the single-occurrence check below.
legacy_target=/usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service
fixture_target="$TMPDIR/missing/omarchy-brightness-keyboard-auto.service"
fixture_migration="$TMPDIR/repair.sh"
# Single exact replacement: no dependence on whether the host installed the unit.
python3 - "$migration" "$fixture_migration" "$legacy_target" "$fixture_target" <<'PY'
import pathlib, sys
source, destination, old, new = sys.argv[1:]
text = pathlib.Path(source).read_text()
assert text.count(old) == 1, "migration must name the exact historical target once"
pathlib.Path(destination).write_text(text.replace(old, new))
PY

# The 1788139121 fallback wrote this link before the unit was packaged; on a
# wedged machine it dangles. Everything else in the directory must survive.
ln -s "$fixture_target" "$wants_dir/omarchy-brightness-keyboard-auto.service"
ln -s "$TMPDIR/missing/custom.service" "$wants_dir/custom.service"
printf 'keep\n' >"$wants_dir/personal.service"
touch "$TMPDIR/omarchy-sleep-lock.service"
ln -s "$TMPDIR/omarchy-sleep-lock.service" "$wants_dir/omarchy-sleep-lock.service"

mock_bin="$TMPDIR/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/systemctl" <<'SH'
#!/bin/bash
echo "$*" >>"$SYSTEMCTL_LOG"
[[ ${SYSTEMCTL_NO_USER_MANAGER:-0} == 1 ]] && exit 1
if [[ $2 == "enable" && $4 == "omarchy-sleep-lock.service" && ${SYSTEMCTL_FAIL_SLEEP:-0} == "1" ]]; then
  exit 42
fi
exit 0
SH
chmod +x "$mock_bin/systemctl"
log="$TMPDIR/calls"

run_repair() {
  HOME="$fake_home" OMARCHY_PATH="$ROOT" SYSTEMCTL_LOG="$log" PATH="$mock_bin:$PATH" \
    bash -euo pipefail "$fixture_migration" >/dev/null
}

: >"$log"
run_repair || fail "the migration completes against a wedged home"
[[ ! -e "$wants_dir/omarchy-brightness-keyboard-auto.service" &&
   ! -L "$wants_dir/omarchy-brightness-keyboard-auto.service" ]] ||
  fail "the dangling legacy wants symlink is removed"
[[ -L "$wants_dir/omarchy-sleep-lock.service" ]] || fail "valid wants symlinks are kept"
grep -Fq 'omarchy-brightness-keyboard-auto.service' "$log" ||
  fail "the migration re-runs the first-run unit enable" "$(cat "$log")"
grep -Fq -- '--user enable --now' "$log" ||
  fail "units are enabled through enable-user-units.sh" "$(cat "$log")"
pass "the migration drops the legacy dangling symlink and re-enables the shipped units"

[[ -L "$wants_dir/custom.service" ]] || fail "unrelated dangling link is preserved"
[[ $(readlink "$wants_dir/custom.service") == "$TMPDIR/missing/custom.service" ]] ||
  fail "custom target is unchanged"
[[ $(<"$wants_dir/personal.service") == "keep" ]] || fail "regular file is preserved"
brightness_link="$wants_dir/omarchy-brightness-keyboard-auto.service"
ln -s "$TMPDIR/missing/user-choice.service" "$brightness_link"
run_repair || fail "custom same-name link does not fail cleanup"
[[ $(readlink "$brightness_link") == "$TMPDIR/missing/user-choice.service" ]] ||
  fail "same-name custom dangling link is preserved"
rm "$brightness_link"
mkdir -p "$(dirname "$fixture_target")"
touch "$fixture_target"
ln -s "$fixture_target" "$brightness_link"
run_repair || fail "valid legacy target is harmless"
[[ -L $brightness_link && -e $brightness_link ]] || fail "valid legacy link is preserved"
rm "$brightness_link"
printf 'user unit\n' >"$brightness_link"
run_repair || fail "same-name regular file is harmless"
[[ -f $brightness_link && ! -L $brightness_link ]] || fail "same-name regular file survives"
rm "$brightness_link"
mkdir "$brightness_link"
run_repair || fail "same-name directory is harmless"
[[ -d $brightness_link && ! -L $brightness_link ]] || fail "same-name directory survives"
rmdir "$brightness_link"
rm "$fixture_target"
ln -s "$fixture_target" "$brightness_link"
pass "the migration preserves everything but the exact legacy dangling link"

[[ -L "$wants_dir/omarchy-sleep-lock.service" ]] ||
  fail "repeat runs leave valid symlinks alone"
pass "the migration is idempotent"

# No user manager (TTY/SSH update): the repair cannot happen, so the
# migration must stay pending instead of marking itself complete.
: >"$log"
if HOME="$fake_home" OMARCHY_PATH="$ROOT" SYSTEMCTL_LOG="$log" \
  SYSTEMCTL_NO_USER_MANAGER=1 PATH="$mock_bin:$PATH" \
  bash -euo pipefail "$fixture_migration" >/dev/null 2>&1; then
  fail "the migration exits non-zero without a live user manager"
fi
[[ -L $brightness_link ]] || fail "manager failure must precede cleanup"
pass "the migration stays pending without a live user manager"

# A required unit that fails to enable must propagate out of the migration so
# the runner leaves it pending and the repair is retried.
if SYSTEMCTL_FAIL_SLEEP=1 run_repair; then
  fail "required enable failure must leave migration pending"
fi
run_repair || fail "retry succeeds after the transient failure clears"
run_repair || fail "completed cleanup remains idempotent"
pass "a failed required enable keeps the migration pending until it succeeds"
