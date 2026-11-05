#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

stub_dir=$(mktemp -d)
fixture=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$fixture"' EXIT

# Keep the package half of the check quiet.
printf '#!/bin/bash\nexit 1\n' >"$stub_dir/pacman"
chmod +x "$stub_dir/pacman"

commit() {
  git -C "$1" -c user.email=test@test -c user.name=test commit -qm "$2" --allow-empty
}

# Bare origin + a seed clone that publishes to it + the checkout under test.
git init -q --bare -b main "$fixture/origin.git"
git init -q "$fixture/seed"
commit "$fixture/seed" initial
git -C "$fixture/seed" remote add origin "$fixture/origin.git"
git -C "$fixture/seed" push -q origin HEAD:main
git clone -q "$fixture/origin.git" "$fixture/work"

run_check() {
  OMARCHY_PATH="$fixture/work" PATH="$stub_dir:$PATH" "$ROOT/bin/omarchy-update-available" 2>&1
}

# 1. Behind upstream by commits only, but HEAD already contains the newest
# release tag: no update.
git -C "$fixture/seed" tag v1.0
git -C "$fixture/seed" push -q origin v1.0
git -C "$fixture/work" pull -q
commit "$fixture/seed" later-1
commit "$fixture/seed" later-2
git -C "$fixture/seed" push -q origin HEAD:main
output=$(run_check) && fail "update reported while newest release tag is contained in HEAD" || true
grep -q "up to date" <<<"$output" || fail "unexpected output when no release is pending: $output"
pass "commits past the newest release do not report an update"

# 2. A new release tag lands upstream: update reported, named by tag.
commit "$fixture/seed" release-1.1
git -C "$fixture/seed" tag v1.1
git -C "$fixture/seed" push -q origin HEAD:main --tags
output=$(run_check) || fail "pending release tag not reported"
grep -q "release v1.1" <<<"$output" || fail "update output does not name the release: $output"
pass "a new upstream release tag reports an update"

# 3. Upstream has no tags at all: fall back to commit count.
git init -q --bare -b main "$fixture/tagless.git"
git init -q "$fixture/tseed"
commit "$fixture/tseed" a
git -C "$fixture/tseed" remote add origin "$fixture/tagless.git"
git -C "$fixture/tseed" push -q origin HEAD:main
git clone -q "$fixture/tagless.git" "$fixture/twork"
commit "$fixture/tseed" b
commit "$fixture/tseed" c
git -C "$fixture/tseed" push -q origin HEAD:main
output=$(OMARCHY_PATH="$fixture/twork" PATH="$stub_dir:$PATH" "$ROOT/bin/omarchy-update-available" 2>&1) ||
  fail "commit fallback did not report an update"
grep -q "2 new commits" <<<"$output" || fail "commit fallback output unexpected: $output"
pass "tagless upstream still reports behind-by-commits"

# 4. Fully up to date: quiet.
git -C "$fixture/work" pull -q
output=$(run_check) && fail "up-to-date checkout reported an update" || true
grep -q "up to date" <<<"$output" || fail "unexpected output when up to date: $output"
pass "up-to-date checkout stays quiet"
