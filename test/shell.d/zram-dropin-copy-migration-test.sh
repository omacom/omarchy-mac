#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1790328426.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
printf '#!/bin/bash\nexec "$@"\n' >"$work/bin/sudo"
chmod +x "$work/bin/sudo"

# $1: vendor drop-in content or "absent", $2: /etc copy content, "absent" or
# "link". Prints what is left at the copy's path.
run_migration() {
  local root="$work/root"
  rm -rf "$root"
  mkdir -p "$root/usr" "$root/etc/systemd/zram-generator.conf.d"
  [[ $1 == absent ]] || { mkdir -p "$root/usr/zram"; printf '%s\n' "$1" >"$root/usr/zram/90-omarchy.conf"; }
  case $2 in
    absent) ;;
    link) ln -s "$root/usr/zram/90-omarchy.conf" "$root/etc/systemd/zram-generator.conf.d/90-omarchy.conf" ;;
    *) printf '%s\n' "$2" >"$root/etc/systemd/zram-generator.conf.d/90-omarchy.conf" ;;
  esac

  OMARCHY_ZRAM_DROPIN_USR="$root/usr/zram/90-omarchy.conf" \
    OMARCHY_ZRAM_DROPIN_ETC="$root/etc/systemd/zram-generator.conf.d/90-omarchy.conf" \
    PATH="$work/bin:$PATH" bash -euo pipefail "$migration" >/dev/null

  if [[ -L $root/etc/systemd/zram-generator.conf.d/90-omarchy.conf ]]; then
    echo link
  elif [[ -f $root/etc/systemd/zram-generator.conf.d/90-omarchy.conf ]]; then
    cat "$root/etc/systemd/zram-generator.conf.d/90-omarchy.conf"
  elif [[ -d $root/etc/systemd/zram-generator.conf.d ]]; then
    echo empty-dir
  else
    echo gone
  fi
}

[[ $(run_migration '[zram0]' '[zram0]') == gone ]] || fail "an identical copy and its directory are removed"
pass "an identical /etc copy of the packaged drop-in is retired"

[[ $(run_migration '[zram0]' '[zram0] edited') == "[zram0] edited" ]] || fail "an edited copy stays"
[[ $(run_migration absent '[zram0]') == "[zram0]" ]] || fail "the copy stays while the package ships no drop-in"
[[ $(run_migration '[zram0]' link) == link ]] || fail "a symlink is not a copy"
[[ $(run_migration '[zram0]' absent) == empty-dir ]] || fail "nothing to retire is a no-op"
pass "an edited copy, a symlink or a missing packaged drop-in leaves /etc alone"
