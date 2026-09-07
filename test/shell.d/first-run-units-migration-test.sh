#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1788782695.sh"

[[ -f $migration ]] || fail "the unpackaged-units repair migration ships"
[[ ! -x $migration ]] || fail "migration files are 0644, not executable"
head -1 "$migration" | grep -q '^echo ' || fail "the migration starts with an echo description"
pass "the unpackaged-units repair migration ships in migration format"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
fake_home="$TMPDIR/home"
wants_dir="$fake_home/.config/systemd/user/graphical-session.target.wants"
mkdir -p "$wants_dir"

# The 1788139121 fallback wrote this link before the unit was packaged; on a
# wedged machine it dangles. A link to a unit that ships must survive.
ln -s "$TMPDIR/nowhere/omarchy-brightness-keyboard-auto.service" \
  "$wants_dir/omarchy-brightness-keyboard-auto.service"
touch "$TMPDIR/omarchy-sleep-lock.service"
ln -s "$TMPDIR/omarchy-sleep-lock.service" "$wants_dir/omarchy-sleep-lock.service"

mock_bin="$TMPDIR/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/systemctl" <<'SH'
#!/bin/bash
echo "$*" >>"$SYSTEMCTL_LOG"
[[ ${SYSTEMCTL_NO_USER_MANAGER:-0} == 1 ]] && exit 1
exit 0
SH
chmod +x "$mock_bin/systemctl"
log="$TMPDIR/calls"

: >"$log"
HOME="$fake_home" OMARCHY_PATH="$ROOT" SYSTEMCTL_LOG="$log" PATH="$mock_bin:$PATH" \
  bash -euo pipefail "$migration" >/dev/null ||
  fail "the migration completes against a wedged home"
[[ ! -e "$wants_dir/omarchy-brightness-keyboard-auto.service" &&
   ! -L "$wants_dir/omarchy-brightness-keyboard-auto.service" ]] ||
  fail "the dangling wants symlink is removed"
[[ -L "$wants_dir/omarchy-sleep-lock.service" ]] || fail "valid wants symlinks are kept"
grep -Fq 'omarchy-brightness-keyboard-auto.service' "$log" ||
  fail "the migration re-runs the first-run unit enable" "$(cat "$log")"
grep -Fq -- '--user enable --now' "$log" ||
  fail "units are enabled through enable-user-units.sh" "$(cat "$log")"
pass "the migration drops dangling wants symlinks and re-enables the shipped units"

: >"$log"
HOME="$fake_home" OMARCHY_PATH="$ROOT" SYSTEMCTL_LOG="$log" PATH="$mock_bin:$PATH" \
  bash -euo pipefail "$migration" >/dev/null ||
  fail "the migration is idempotent on an already-repaired home"
[[ -L "$wants_dir/omarchy-sleep-lock.service" ]] ||
  fail "a second run leaves valid symlinks alone"
pass "the migration is idempotent"

# No user manager (TTY/SSH update): the repair cannot happen, so the
# migration must stay pending instead of marking itself complete.
: >"$log"
if HOME="$fake_home" OMARCHY_PATH="$ROOT" SYSTEMCTL_LOG="$log" \
  SYSTEMCTL_NO_USER_MANAGER=1 PATH="$mock_bin:$PATH" \
  bash -euo pipefail "$migration" >/dev/null 2>&1; then
  fail "the migration exits non-zero without a live user manager"
fi
pass "the migration stays pending without a live user manager"
