#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/pacman" <<'SH'
#!/bin/bash
[[ $* == "-Qq" ]] || exit 91
[[ ${QUERY_FAIL:-0} == 0 ]] || exit 1
printf '%s\n' "$PACKAGES"
SH
chmod +x "$tmp/pacman"
export PATH="$tmp:$PATH"
for kernel in linux-asahi linux-aurora; do
  [[ $(PACKAGES="$kernel" "$ROOT/bin/omarchy-mac-kernel") == "$kernel" ]] || fail "installed $kernel is selected"
done
for packages in '' linux $'linux-asahi\nlinux-aurora'; do
  if PACKAGES="$packages" "$ROOT/bin/omarchy-mac-kernel"; then fail "missing or ambiguous kernel is refused"; fi
done
if QUERY_FAIL=1 PACKAGES=linux-asahi "$ROOT/bin/omarchy-mac-kernel"; then fail "package query failure is refused"; fi
pass "kernel selection uses installed packages and refuses missing or ambiguous results"
