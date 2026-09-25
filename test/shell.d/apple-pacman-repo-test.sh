#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/pacman.sh"
hardware_pacman="$ROOT/install/hardware/pacman.sh"
migration="$ROOT/migrations/1788200000.sh"

# The unsigned [omarchy-aarch64] is legacy: only the migration reaches the leaf.
# Fresh installs and images take every package signed from [omarchy], asahi-alarm
# and Arch Linux ARM.
hardware_all="$ROOT/install/hardware/all.sh"
! grep -Fq 'apple/pacman.sh' "$hardware_all" ||
  fail "fresh hardware setup, and so an image's deferred queue, never runs the [omarchy-aarch64] leaf"
! grep -Fq 'apple/pacman.sh' "$hardware_pacman" ||
  fail "the pacman extensions never run the [omarchy-aarch64] leaf"
pass "fresh hardware setup never runs the [omarchy-aarch64] leaf"

# On installs that have it, every Apple Silicon migration still runs after the
# repository exists, whether it installs directly or through a sourced leaf;
# the runner walks migrations in filename order. A migration counts as Apple
# Silicon when it names the detector, the architecture, or an Apple leaf; one
# that exits on the detector is Intel-only and exempt, and so are older
# upstream migrations that only mention an Asahi package name.
late=()
for candidate in "$ROOT"/migrations/*.sh; do
  [[ $(basename "$candidate") != $(basename "$migration") ]] || continue
  ! grep -Fq 'omarchy-hw-apple-silicon && exit 0' "$candidate" || continue
  grep -Eq 'omarchy-hw-apple-silicon|aarch64|hardware/apple/' "$candidate" || continue
  [[ $(basename "$candidate") > $(basename "$migration") ]] || late+=("$(basename "$candidate")")
done
(( ${#late[@]} == 0 )) ||
  fail "the repository migration sorts before every Apple Silicon migration" "$(printf '%s\n' "${late[@]}")"
pass "the [omarchy-aarch64] migration runs before its consumers"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls"
conf="$test_tmp/pacman.conf"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
[[ ${APPLE_SILICON:-0} == "1" ]]
SH
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
exec "$@"
SH
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$TEST_LOG"
exit "${PACMAN_SY_STATUS:-0}"
SH
# An Apple Silicon Mac has no T2 or other PCI device the pacman leaves look for.
printf '#!/bin/bash\n' >"$stub_bin/lspci"
chmod +x "$stub_bin"/*

stock_conf() {
  printf '%s\n' '[options]' 'Architecture = auto' '' '[core]' 'Include = /etc/pacman.d/mirrorlist' >"$conf"
}

pending="$test_tmp/var/lib/omarchy/migrations/omarchy-aarch64-sync-pending"
# A Mac installed before images, unless a test names an image-built one.
export OMARCHY_IMAGE_ROOT="$test_tmp/legacy-root"

run_leaf() {
  : >"$calls"
  APPLE_SILICON="${1:-0}" OMARCHY_PACMAN_CONF="$conf" OMARCHY_AARCH64_REPO_PENDING="$pending" TEST_LOG="$calls" PATH="$stub_bin:$PATH" \
    bash -euo pipefail -c 'source "$1"' _ "$leaf"
}

run_migration() {
  : >"$calls"
  APPLE_SILICON="${1:-0}" OMARCHY_PACMAN_CONF="$conf" OMARCHY_AARCH64_REPO_PENDING="$pending" OMARCHY_PATH="$ROOT" TEST_LOG="$calls" PATH="$stub_bin:$PATH" \
    bash -euo pipefail "$migration"
}

unsigned_repository() {
  grep -Eq '^\[omarchy-aarch64\]|TrustAll' "$conf"
}

# A fresh Apple Silicon hardware setup, run or deferred to an image's first
# boot, configures no unsigned repository: run every listed leaf that touches
# pacman's configuration on a stubbed Mac.
stock_conf
: >"$calls"
while IFS= read -r step; do
  grep -Eq 'pacman\.conf|pacman -Sy' "$ROOT/$step" || continue
  APPLE_SILICON=1 OMARCHY_PACMAN_CONF="$conf" OMARCHY_AARCH64_REPO_PENDING="$pending" TEST_LOG="$calls" \
    PATH="$stub_bin:$PATH" bash -euo pipefail -c 'source "$1"' _ "$ROOT/$step" >/dev/null ||
    fail "$step runs on a stubbed Mac"
done < <(sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(hardware/[^"]*\)"$|install/\1|p' "$hardware_all")
! unsigned_repository || fail "a fresh Apple Silicon setup leaves pacman.conf with no unsigned repository" "$(cat "$conf")"
[[ ! -s $calls ]] || fail "a fresh Apple Silicon setup fetches no repository database" "$(cat "$calls")"
pass "a fresh Apple Silicon setup leaves pacman.conf with no [omarchy-aarch64] and no TrustAll"

# An image-built Mac, before or after its first boot, never gets the repository,
# from the migration or from a queue an older image deferred.
for marker in target target.booted; do
  image_root="$test_tmp/image-$marker"
  mkdir -p "$image_root/var/lib/omarchy/image"
  : >"$image_root/var/lib/omarchy/image/$marker"
  stock_conf
  OMARCHY_IMAGE_ROOT="$image_root" run_leaf 1
  OMARCHY_IMAGE_ROOT="$image_root" run_migration 1
  ! unsigned_repository && [[ ! -s $calls && ! -e $pending ]] ||
    fail "an image-built Mac ($marker) never gets the [omarchy-aarch64] repository" "$(cat "$conf" "$calls")"
done
pass "an image-built Mac never gets the [omarchy-aarch64] repository"

stock_conf
before=$(cat "$conf")
run_leaf 0
[[ $(cat "$conf") == "$before" ]] || fail "the leaf leaves pacman.conf alone off Apple Silicon"
pass "the leaf is a no-op off Apple Silicon"

run_leaf 1
grep -Fxq '[omarchy-aarch64]' "$conf" || fail "Apple Silicon gets the [omarchy-aarch64] stanza" "$(cat "$conf")"
grep -Fxq 'Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge' "$conf" ||
  fail "the stanza points at the omarchy-pkgs-aarch64 releases"
grep -Fxq 'SigLevel = Optional TrustAll' "$conf" || fail "the stanza declares the unsigned repository"
grep -Fxq '[core]' "$conf" || fail "the existing repositories are kept"
grep -Fxq 'pacman -Sy' "$calls" || fail "the leaf fetches the new database" "$(cat "$calls")"
[[ ! -e $pending ]] || fail "a successful fetch clears the pending marker"
pass "Apple Silicon gets the [omarchy-aarch64] repository and its database"

after=$(cat "$conf")
run_leaf 1
[[ $(cat "$conf") == "$after" ]] || fail "the leaf does not append a second stanza"
(( $(grep -c '^\[omarchy-aarch64\]' "$conf") == 1 )) || fail "exactly one stanza is present"
! grep -q 'pacman -Sy' "$calls" || fail "a rerun with nothing owed does not resync" "$(cat "$calls")"
pass "the leaf is idempotent"

# A failed fetch leaves the stanza in place but keeps the sync owed: the leaf
# fails, and the next run fetches again before anything can install from it.
stock_conf
: >"$calls"
if PACMAN_SY_STATUS=1 run_leaf 1 2>/dev/null; then
  fail "a failed database fetch fails the leaf"
fi
grep -Fxq '[omarchy-aarch64]' "$conf" || fail "a failed fetch keeps the stanza"
[[ -f $pending ]] || fail "a failed fetch leaves the sync pending"
run_leaf 1
grep -Fxq 'pacman -Sy' "$calls" || fail "the rerun fetches the database it still owes" "$(cat "$calls")"
[[ ! -e $pending ]] || fail "the rerun clears the pending marker"
pass "a failed database fetch stays pending and retries"

stock_conf
run_migration 0
! grep -q 'omarchy-aarch64' "$conf" || fail "the migration does not write on x86"
[[ ! -s $calls ]] || fail "the migration runs nothing on x86" "$(cat "$calls")"
pass "the migration is a no-op off Apple Silicon"

run_migration 1
grep -Fxq '[omarchy-aarch64]' "$conf" || fail "the migration adds the stanza on Apple Silicon"
grep -Fxq 'pacman -Sy' "$calls" || fail "the migration fetches the new database" "$(cat "$calls")"
pass "the migration adds the repository and syncs its database"

run_migration 1
! grep -q 'pacman -Sy' "$calls" || fail "a rerun does not resync when nothing was added" "$(cat "$calls")"
(( $(grep -c '^\[omarchy-aarch64\]' "$conf") == 1 )) || fail "a rerun does not duplicate the stanza"
pass "the migration is idempotent"

stock_conf
if PACMAN_SY_STATUS=1 run_migration 1 2>/dev/null; then
  fail "the migration stays pending when the database fetch fails"
fi
run_migration 1
grep -Fxq 'pacman -Sy' "$calls" || fail "the retried migration fetches the database" "$(cat "$calls")"
pass "the migration stays pending until the database has been fetched"
