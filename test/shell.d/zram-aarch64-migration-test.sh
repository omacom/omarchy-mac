#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1790328426.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
printf '#!/bin/bash\nexec "$@"\n' >"$work/bin/sudo"
printf '#!/bin/bash\nprintf "%%s\\n" $DEFAULTS\n' >"$work/bin/omarchy-pkg-defaults"
printf '#!/bin/bash\n[[ $MISSING == 1 ]]\n' >"$work/bin/omarchy-pkg-missing"
printf '#!/bin/bash\necho "pkg-add $*" >>"$CALLS"\n' >"$work/bin/omarchy-pkg-add"
cat >"$work/bin/systemctl" <<'SH'
#!/bin/bash
echo "systemctl $*" >>"$CALLS"
[[ $1 != "is-active" ]] || [[ $ZRAM_ACTIVE == 1 ]]
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

# zram-generator: installed and started only where the platform's defaults name
# it and it is missing.
MISSING=1 run_migration '[zram0]' absent >/dev/null
[[ ! -s $CALLS ]] || fail "a platform without zram-generator in its defaults installs nothing" "$(cat "$CALLS")"
DEFAULTS="base-package zram-generator" MISSING=0 run_migration '[zram0]' absent >/dev/null
[[ ! -s $CALLS ]] || fail "an installed zram-generator is left alone" "$(cat "$CALLS")"
DEFAULTS="base-package zram-generator" MISSING=1 run_migration '[zram0]' absent >/dev/null
grep -Fxq 'pkg-add zram-generator' "$CALLS" || fail "aarch64 installs zram-generator"
grep -Fxq 'systemctl start systemd-zram-setup@zram0.service' "$CALLS" || fail "the zram device is started"
: >"$CALLS"
DEFAULTS="base-package zram-generator" MISSING=1 ZRAM_ACTIVE=1 run_migration '[zram0]' absent >/dev/null
! grep -Fq 'systemctl start' "$CALLS" || fail "an active zram swap is not restarted"
pass "zram-generator is installed and started where the platform's defaults name it"
