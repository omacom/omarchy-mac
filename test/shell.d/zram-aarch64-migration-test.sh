#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1790328426.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
printf '#!/bin/bash\nexec "$@"\n' >"$work/bin/sudo"
printf '#!/bin/bash\n[[ $DEFAULTS != fail ]] || exit 1\nprintf "%%s\\n" $DEFAULTS\n' >"$work/bin/omarchy-pkg-defaults"
printf '#!/bin/bash\n[[ $MISSING == 1 ]]\n' >"$work/bin/omarchy-pkg-missing"
printf '#!/bin/bash\necho "pkg-add $*" >>"$CALLS"\n' >"$work/bin/omarchy-pkg-add"
# ZRAM_ACTIVE: the swap is up. ZRAM_UNIT: the generator's swap unit's load
# state (not-found where no device is configured). ZRAM_START: its start status.
cat >"$work/bin/systemctl" <<'SH'
#!/bin/bash
echo "systemctl $*" >>"$CALLS"
case $1 in
  is-active) (( ZRAM_ACTIVE == 1 )) ;;
  show) [[ ${ZRAM_UNIT:-loaded} != fail ]] && echo "${ZRAM_UNIT:-loaded}" ;;
  start) exit "${ZRAM_START:-0}" ;;
esac
SH
chmod +x "$work/bin/"*

# $1: vendor drop-in content or "absent", $2: /etc copy content, "absent" or
# "link". Prints what is left at the copy's path.
run_migration() {
  local root="$work/root"
  rm -rf "$root"
  mkdir -p "$root/usr" "$root/etc/systemd/zram-generator.conf.d"
  if [[ $1 != "absent" ]]; then
    mkdir -p "$root/usr/zram"
    printf '%s\n' "$1" >"$root/usr/zram/90-omarchy.conf"
  fi
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

export CALLS="$work/calls" DEFAULTS="base-package" MISSING=0 ZRAM_ACTIVE=0
: >"$CALLS"

[[ $(run_migration '[zram0]' '[zram0]') == "gone" ]] || fail "an identical copy and its directory are removed"
pass "an identical /etc copy of the packaged drop-in is retired"

[[ $(run_migration '[zram0]' '[zram0] edited') == "[zram0] edited" ]] || fail "an edited copy stays"
[[ $(run_migration absent '[zram0]') == "[zram0]" ]] || fail "the copy stays while the package ships no drop-in"
[[ $(run_migration '[zram0]' link) == "link" ]] || fail "a symlink is not a copy"
[[ $(run_migration '[zram0]' absent) == "empty-dir" ]] || fail "nothing to retire is a no-op"
pass "an edited copy, a symlink or a missing packaged drop-in leaves /etc alone"

# zram-generator: installed where the platform's defaults name it, and its swap
# started wherever it is down.
: >"$CALLS"
MISSING=1 run_migration '[zram0]' absent >/dev/null
[[ ! -s $CALLS ]] || fail "a platform without zram-generator in its defaults changes nothing" "$(cat "$CALLS")"
DEFAULTS="base-package zram-generator" MISSING=0 ZRAM_ACTIVE=1 run_migration '[zram0]' absent >/dev/null
[[ $(cat "$CALLS") == "systemctl is-active --quiet dev-zram0.swap" ]] || fail "a running zram swap is left alone" "$(cat "$CALLS")"
: >"$CALLS"
DEFAULTS="base-package zram-generator" MISSING=1 run_migration '[zram0]' absent >/dev/null
grep -Fxq 'pkg-add zram-generator' "$CALLS" || fail "aarch64 installs zram-generator"
grep -Fxq 'systemctl start dev-zram0.swap' "$CALLS" || fail "the zram swap is started" "$(cat "$CALLS")"
: >"$CALLS"
DEFAULTS="base-package zram-generator" MISSING=0 run_migration '[zram0]' absent >/dev/null
! grep -Fq 'pkg-add' "$CALLS" || fail "an installed zram-generator is not installed again"
grep -Fxq 'systemctl start dev-zram0.swap' "$CALLS" || fail "an installed generator whose swap is down gets it started" "$(cat "$CALLS")"
: >"$CALLS"
DEFAULTS="base-package zram-generator" MISSING=0 ZRAM_UNIT=not-found run_migration '[zram0]' absent >/dev/null
! grep -Fq 'systemctl start' "$CALLS" || fail "no device configured, nothing started" "$(cat "$CALLS")"
: >"$CALLS"
DEFAULTS="base-package zram-generator" MISSING=0 ZRAM_UNIT=masked run_migration '[zram0]' absent >/dev/null
! grep -Fq 'systemctl start' "$CALLS" || fail "a masked swap unit is the administrator's choice" "$(cat "$CALLS")"
pass "zram-generator is installed where the platform's defaults name it, and its swap started unless configured away"

for unit in fail bad-setting; do
  status=0
  DEFAULTS="base-package zram-generator" MISSING=0 ZRAM_UNIT=$unit PATH="$work/bin:$PATH" bash -euo pipefail "$migration" >/dev/null 2>&1 || status=$?
  (( status != 0 )) || fail "a swap unit that can't be read or loaded fails the migration ($unit)"
done
pass "a swap unit that can't be read or loaded fails the migration, so it runs again"

status=0
DEFAULTS="base-package zram-generator" MISSING=0 ZRAM_START=1 PATH="$work/bin:$PATH" bash -euo pipefail "$migration" >/dev/null 2>&1 || status=$?
(( status != 0 )) || fail "a zram swap that won't start fails the migration, so it runs again"
pass "a zram swap that won't start fails the migration"

: >"$CALLS"
status=0
DEFAULTS=fail MISSING=1 PATH="$work/bin:$PATH" bash -euo pipefail "$migration" >/dev/null 2>&1 || status=$?
(( status == 75 )) || fail "a platform that can't be told defers the migration" "status $status"
[[ ! -s $CALLS ]] || fail "a platform that can't be told installs nothing" "$(cat "$CALLS")"
pass "a platform that can't be told defers the migration and changes nothing"
