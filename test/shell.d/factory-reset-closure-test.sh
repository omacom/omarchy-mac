#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/install/helpers/factory-reset.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
fixture_root="$test_tmp/old-root"
mkdir -p "$fixture_root/usr/bin" "$fixture_root/usr/share/omarchy/bin" "$fixture_root/usr/share/omarchy/install/helpers"
# Historical package aliases must be replaced as directory entries, without
# following an absolute alias into this process's actual filesystem.
ln -s /unavailable-historical-target "$fixture_root/usr/share/omarchy/bin/omarchy-provision-owner"
ln -s ../share/omarchy/bin/omarchy-provision-owner "$fixture_root/usr/bin/omarchy-provision-owner"
reset_closure_install "$ROOT" "$fixture_root" "$test_tmp/closure.sha256"
while IFS= read -r file; do
  cmp "$ROOT/$file" "$fixture_root/usr/share/omarchy/$file" || fail "current closure $file"
  if [[ $file == bin/* ]]; then cmp "$ROOT/$file" "$fixture_root/usr/bin/${file#bin/}" || fail 'installed binary closure'; fi
done < <(reset_closure_files)
[[ ! -L $fixture_root/usr/bin/omarchy-provision-owner && ! -L $fixture_root/usr/share/omarchy/bin/omarchy-provision-owner ]] || fail 'historical aliases remain'
grep -q '/usr/bin/omarchy-provision-owner$' "$test_tmp/closure.sha256" || fail 'actual executable is bound'
grep -q '/install/helpers/browser-policy.sh$' "$test_tmp/closure.sha256" || fail 'browser helper closure'
grep -q '/install/helpers/as-root.sh$' "$test_tmp/closure.sha256" || fail 'transitive privilege helper closure'
pass 'exact current worker and transitive closure replace historical aliases safely'
mkdir -p "$test_tmp/other-root/usr/share"
ln -s "$test_tmp/outside" "$test_tmp/other-root/usr/share/omarchy"
if reset_closure_install "$ROOT" "$test_tmp/other-root" "$test_tmp/rejected.sha256"; then fail 'symlinked closure parent'; fi
[[ ! -e $test_tmp/outside ]] || fail 'outside target touched'
pass 'historical development-link parent fails without escaping selected root'
