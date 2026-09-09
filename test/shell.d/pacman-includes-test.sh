#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

post_install="$ROOT/install/post-install/pacman.sh"

# post-install/pacman.sh overwrites /etc/pacman.conf with one of these variants.
# pacman refuses to parse a config whose Include is missing, so every included
# file has to be installed alongside it or the system loses pacman entirely.
missing=()
while read -r included; do
  base=${included##*/}
  grep -qF "$base" "$post_install" || missing+=("$included")
done < <(grep -h '^Include = /etc/pacman.d/' "$ROOT"/default/pacman/pacman*.conf "$ROOT"/default/pacman/aarch64/pacman*.conf |
  awk '{ print $3 }' | sort -u)

if (( ${#missing[@]} )); then
  fail "pacman config restore installs every mirrorlist it includes" \
    "not installed by post-install/pacman.sh:$(printf '\n  %s' "${missing[@]}")"
fi
pass "pacman config restore installs every mirrorlist it includes"

# The source has to ship too, or the copy above silently does nothing.
# x86 lists live in default/pacman/; ARM lists live in default/pacman/aarch64/.
while read -r included; do
  base=${included##*/}
  [[ $base == "mirrorlist" ]] && continue
  [[ -f "$ROOT/default/pacman/$base" || -f "$ROOT/default/pacman/aarch64/$base" ]] ||
    fail "the included mirrorlist ships in the repo" "missing: default/pacman/$base"
done < <(grep -h '^Include = /etc/pacman.d/' "$ROOT"/default/pacman/pacman*.conf "$ROOT"/default/pacman/aarch64/pacman*.conf |
  awk '{ print $3 }' | sort -u)
pass "every included mirrorlist ships in the repo"

# The installed mirrorlist is the one Asahi Alarm set up, often with mirrors
# close to the user. Replacing it leaves a single slow generic server, which is
# what omarchy-refresh-pacman-mirrorlist exists to avoid.
if grep -qE '^cp -f .*mirrorlist-\$\{OMARCHY_MIRROR' "$post_install"; then
  fail "pacman config restore does not overwrite the installed mirrorlist"
fi
grep -qF 'grep -qxF "$mirror_line" /etc/pacman.d/mirrorlist' "$post_install" ||
  fail "pacman config restore appends only mirrors that are missing"
pass "pacman config restore keeps the mirrors the machine was installed with"
