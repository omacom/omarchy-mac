# shellcheck shell=dash
# Package-owned device tree overlays for m1n1 stage 2 (sh with local).
#
# A package that adds hardware support the kernel's device trees lack ships a
# compiled overlay as /usr/share/omarchy-platform/dtb-overlays/PREFIX/NAME.dtbo.
# It applies to every device tree whose file name is PREFIX.dtb or starts with
# PREFIX- ("t8103" covers every M1 board, "t6001-j316c" one board). A device
# tree takes its overlays in C order of PREFIX/NAME. An overlay whose root node
# has the string list "omarchy,skip-if-compatible" is left out of a device tree
# that already has an available node with one of those compatibles (Linux's
# of_device_is_available(): no status, "okay" or "ok"), so a kernel that gains
# the node wins. An overlay whose root node has the string "omarchy,opt-in"
# applies only when that string is a line of
# /etc/omarchy-platform/dtb-overlays.opt-in: the owner's choice for hardware
# whose driver must not start by default. When an overlay does not apply, or
# dtc cannot read the result, that device tree stays as the kernel shipped it.
# With no overlays, nothing changes.
#
# /etc/default/update-m1n1 calls dtb_overlays_update_m1n1 to set DTBS, and
# omarchy-apple-silicon-boot-check calls dtb_overlays_apply to rebuild the same
# image. OMARCHY_DTB_OVERLAYS=0 turns the update-m1n1 side off, so the boot
# check can read the configuration without building anything.
# OMARCHY_DTB_OVERLAYS_ROOT prefixes every path read or written (tests, and the
# boot check's root).

dtb_overlays_dir() {
  printf '%s\n' "${OMARCHY_DTB_OVERLAYS_ROOT:-}/usr/share/omarchy-platform/dtb-overlays"
}

# The overlays, one path per line, in the order they apply.
dtb_overlays_list() {
  (
    LC_ALL=C
    for overlay in "$(dtb_overlays_dir)"/*/*.dtbo; do
      if [ -f "$overlay" ]; then
        printf '%s\n' "$overlay"
      fi
    done
  )
}

# dtc, fdtoverlay and fdtget, from dtc 1.7.1 or newer: older fdtoverlay gives
# an existing node a new phandle when an overlay labels it, and every
# reference to the old one then points nowhere.
dtb_overlays_tools() {
  local version
  command -v dtc >/dev/null 2>&1 && command -v fdtoverlay >/dev/null 2>&1 &&
    command -v fdtget >/dev/null 2>&1 || return 1
  # "Version: DTC v1.8.1" on Arch, "Version: DTC 1.6.1" on Debian.
  version=$(dtc --version 2>/dev/null | sed -n 's/^Version: DTC v\{0,1\}\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\).*/\1 \2 \3/p')
  # shellcheck disable=SC2086 # split into major minor patch
  set -- $version
  [ $# = 3 ] || return 1
  [ "$1" -gt 1 ] || { [ "$1" = 1 ] && { [ "$2" -gt 7 ] || { [ "$2" = 7 ] && [ "$3" -ge 1 ]; }; }; }
}

# True when UPDATE_M1N1 has the DTBS default dtb_overlays_update_m1n1
# reproduces: asahi-scripts with the default Arch Linux ARM adds.
dtb_overlays_supported() {
  # shellcheck disable=SC2016 # the literal default line
  grep -Fqx -- ': ${DTBS:=$(/bin/ls -d /lib/modules/*-ARCH | sort -rV | head -1)/dtbs/*.dtb}' "$1"
}

# True when DTB has an available node whose compatible list holds COMPATIBLE.
# Available is Linux's of_device_is_available(): the node has no status, or
# its status is "okay" or "ok". A disabled node does not count.
dtb_overlays_has_compatible() {
  dtc -q -I dtb -O dts -o - "$1" 2>/dev/null | awk -v compatible="\"$2\"" '
    {
      if ($0 ~ /^[[:space:]]*\}[;]?[[:space:]]*$/) {
        if (matched[depth] && (status[depth] == "" || status[depth] == "okay" ||
          status[depth] == "ok")) {
          found = 1
          exit
        }
        delete matched[depth]
        delete status[depth]
        depth--
      } else if ($0 ~ /\{[[:space:]]*$/) {
        depth++
      } else if ($0 ~ /^[[:space:]]*compatible[[:space:]]*=/ && index($0, compatible)) {
        matched[depth] = 1
      } else if ($0 ~ /^[[:space:]]*status[[:space:]]*=/ && match($0, /"[^"]*"/)) {
        status[depth] = substr($0, RSTART + 1, RLENGTH - 2)
      }
    }
    END { exit found ? 0 : 1 }
  '
}

# Writes OUT: DTB with every overlay in OVERLAYS (newline-separated) that
# applies to it. Returns 1, and writes nothing, when none applies or one fails.
dtb_overlays_build() {
  local dtb="$1" out="$2" overlays="$3" name="${1##*/}" applied=0 overlay prefix skip compatible key
  local opt_in="${OMARCHY_DTB_OVERLAYS_ROOT:-}/etc/omarchy-platform/dtb-overlays.opt-in"
  cp -- "$dtb" "$out.base" || return 1
  for overlay in $overlays; do
    prefix=${overlay%/*}
    prefix=${prefix##*/}
    case "$name" in
      "$prefix.dtb" | "$prefix"-*) ;;
      *) continue ;;
    esac
    skip=0
    for key in $(fdtget -t s "$overlay" / omarchy,opt-in 2>/dev/null); do
      grep -Fqx -- "$key" "$opt_in" 2>/dev/null || skip=1
    done
    for compatible in $(fdtget -t s "$overlay" / omarchy,skip-if-compatible 2>/dev/null); do
      if dtb_overlays_has_compatible "$out.base" "$compatible"; then
        skip=1
      fi
    done
    [ "$skip" = 0 ] || continue
    if fdtoverlay -i "$out.base" -o "$out.next" "$overlay" 2>/dev/null &&
      dtc -q -I dtb -O dtb -o /dev/null "$out.next" 2>/dev/null; then
      mv -f -- "$out.next" "$out.base"
      applied=1
    else
      echo "dtb-overlays: $overlay does not apply to $name; $name stays as the kernel shipped it" >&2
      rm -f -- "$out.next" "$out.base"
      return 1
    fi
  done
  if [ "$applied" = 0 ]; then
    rm -f -- "$out.base"
    return 1
  fi
  mv -f -- "$out.base" "$out"
}

# Prints each DTB, or the copy of it in OUTDIR that carries its overlays, one
# per line and in the same order.
dtb_overlays_apply() {
  local outdir="$1" overlays dtb
  shift
  overlays=$(dtb_overlays_list)
  if [ -z "$overlays" ] || ! dtb_overlays_tools; then
    overlays=""
  fi
  for dtb in "$@"; do
    if [ -n "$overlays" ] && dtb_overlays_build "$dtb" "$outdir/${dtb##*/}" "$overlays"; then
      printf '%s\n' "$outdir/${dtb##*/}"
    else
      printf '%s\n' "$dtb"
    fi
  done
}

# Sets DTBS for update-m1n1 when an overlay applies to one of the newest
# kernel's device trees; otherwise leaves DTBS as it was.
dtb_overlays_update_m1n1() {
  local root="${OMARCHY_DTB_OVERLAYS_ROOT:-}" modules outdir list="" path
  outdir=$root/run/omarchy-dtb-overlays
  [ "${OMARCHY_DTB_OVERLAYS:-1}" != 0 ] || return 0
  [ -z "${DTBS:-}" ] || return 0
  [ -n "$(dtb_overlays_list)" ] || return 0
  if ! dtb_overlays_supported "$root/usr/bin/update-m1n1"; then
    echo "dtb-overlays: /usr/bin/update-m1n1 has a DTBS default this does not reproduce; device tree overlays are not applied" >&2
    return 0
  fi
  if ! dtb_overlays_tools; then
    echo "dtb-overlays: device tree overlays need dtc 1.7.1 or newer (dtc, fdtoverlay and fdtget); install or update dtc" >&2
    return 0
  fi
  modules=$(/bin/ls -d "$root"/lib/modules/*-ARCH | sort -rV | head -1)
  rm -rf -- "$outdir"
  mkdir -p -- "$outdir" || return 0
  for path in $(dtb_overlays_apply "$outdir" "$modules"/dtbs/*.dtb); do
    list="$list $path"
  done
  case "$list" in
    *" $outdir/"*) DTBS=${list# } ;;
  esac
}
