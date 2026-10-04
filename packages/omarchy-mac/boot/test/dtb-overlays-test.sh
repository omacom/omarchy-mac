#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command dtc
require_command fdtoverlay
require_command fdtget

# shellcheck source=../lib/dtb-overlays.sh
source "$ROOT/lib/dtb-overlays.sh"
dtb_overlays_tools || fail "dtc is 1.7.1 or newer: $(dtc --version)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$tmp/root
export OMARCHY_DTB_OVERLAYS_ROOT=$root
kver=7.1.12-2-11-ARCH
dtbs=$root/lib/modules/$kver/dtbs
overlays=$root/usr/share/omarchy-platform/dtb-overlays
mkdir -p "$dtbs" "$overlays" "$root/usr/bin" "$root/run" "$tmp/out"

# A board device tree: its board and SoC compatibles and one /soc node.
board_dtb() {
  local name=$1 board=$2 soc=$3 extra=${4:-}
  dtc -q -I dts -O dtb -o "$dtbs/$name" - <<DTS
/dts-v1/;
/ {
  compatible = "apple,$board", "apple,$soc";
  #address-cells = <2>;
  #size-cells = <2>;
  soc {
    compatible = "simple-bus";
    #address-cells = <2>;
    #size-cells = <2>;
    ranges;
    serial@1000 { compatible = "apple,s5l-uart"; reg = <0 0x1000 0 0x100>; };
    $extra
  };
};
DTS
}

# An overlay PREFIX/NAME.dtbo that adds /soc/ane@2000 with COMPATIBLE. With
# SKIP, it says to stay out of a tree that already has COMPATIBLE. TARGET is
# the node it adds to. With OPT_IN, it applies only when opted in.
overlay() {
  local prefix=$1 name=$2 compatible=$3 skip=${4:-} target=${5:-/soc} opt_in=${6:-} extra=""
  [[ -z $skip ]] || extra="omarchy,skip-if-compatible = \"$compatible\";"
  [[ -z $opt_in ]] || extra="$extra omarchy,opt-in = \"$opt_in\";"
  mkdir -p "$overlays/$prefix"
  dtc -q -@ -I dts -O dtb -o "$overlays/$prefix/$name.dtbo" - <<DTS
/dts-v1/;
/plugin/;
/ {
  $extra
  fragment@0 {
    target-path = "$target";
    __overlay__ {
      ane@2000 { compatible = "$compatible"; reg = <0 0x2000 0 0x100>; status = "okay"; };
    };
  };
};
DTS
}

has_ane() {
  [[ $(fdtget "$1" /soc/ane@2000 compatible 2>/dev/null) == "$2" ]]
}

board_dtb t6001-j316c.dtb j316c t6001
board_dtb t8103-j274.dtb j274 t8103
board_dtb t8103-j293.dtb j293 t8103
board_dtb t8103-j293-kernel-ane.dtb j293 t8103 'ane@2000 { compatible = "apple,t8103-ane"; reg = <0 0x2000 0 0x100>; };'
stock=("$dtbs/t6001-j316c.dtb" "$dtbs/t8103-j274.dtb" "$dtbs/t8103-j293.dtb")
cp "$dtbs"/*.dtb "$tmp/"

# update-m1n1 as Arch Linux ARM's asahi-scripts ships its DTBS default.
cat >"$root/usr/bin/update-m1n1" <<'SH'
#!/bin/sh
: ${DTBS:=$(/bin/ls -d /lib/modules/*-ARCH | sort -rV | head -1)/dtbs/*.dtb}
cat "$M1N1" $DTBS >"${TARGET}.new"
SH

mapfile -t result < <(dtb_overlays_apply "$tmp/out" "${stock[@]}")
[[ ${result[*]} == "${stock[*]}" && -z $(ls -A "$tmp/out") ]] || fail "with no overlays, every device tree stays the kernel's"
unset DTBS
dtb_overlays_update_m1n1
[[ -z ${DTBS:-} ]] || fail "with no overlays, update-m1n1 keeps its DTBS default"
pass "no overlays change nothing"

overlay t8103 omarchy-ane apple,t8103-ane skip
mapfile -t result < <(dtb_overlays_apply "$tmp/out" "${stock[@]}")
[[ ${result[0]} == "$dtbs/t6001-j316c.dtb" ]] || fail "a t8103 overlay leaves a t6001 device tree alone"
[[ ${result[1]} == "$tmp/out/t8103-j274.dtb" && ${result[2]} == "$tmp/out/t8103-j293.dtb" ]] ||
  fail "a t8103 overlay applies to every t8103 board: ${result[*]}"
for path in "${result[1]}" "${result[2]}"; do
  has_ane "$path" apple,t8103-ane || fail "the overlaid device trees carry the overlay's node"
done
[[ $(fdtget "${result[2]}" / compatible) == "apple,j293 apple,t8103" ]] || fail "the overlaid device tree keeps its board compatibles"
dtc -q -I dtb -O dts -o /dev/null "${result[2]}" || fail "dtc reads the overlaid device tree"
cmp -s "$dtbs/t8103-j293.dtb" "$tmp/t8103-j293.dtb" || fail "the kernel's device tree is not written"
pass "an overlay applies to the device trees its prefix names and nowhere else"

cp "${result[2]}" "$tmp/first.dtb"
mapfile -t result < <(dtb_overlays_apply "$tmp/out" "${stock[@]}")
cmp -s "${result[2]}" "$tmp/first.dtb" || fail "applying the overlays again gives the same bytes"
pass "the overlaid device tree is the same bytes every time"

# dtc before 1.7.1 renumbers a labelled existing node, so it gets no overlays.
mkdir -p "$tmp/old-dtc"
printf '#!/bin/bash\n[[ $1 == --version ]] && { echo "Version: DTC 1.6.1"; exit 0; }\nexec %q "$@"\n' "$(command -v dtc)" >"$tmp/old-dtc/dtc"
chmod +x "$tmp/old-dtc/dtc"
mapfile -t result < <(PATH="$tmp/old-dtc:$PATH" dtb_overlays_apply "$tmp/out" "${stock[@]}")
[[ ${result[*]} == "${stock[*]}" ]] || fail "dtc 1.6.1 gets no overlays: ${result[*]}"
pass "dtc older than 1.7.1 leaves every device tree the kernel's"

mapfile -t result < <(dtb_overlays_apply "$tmp/out" "$dtbs/t8103-j293-kernel-ane.dtb")
[[ ${result[0]} == "$dtbs/t8103-j293-kernel-ane.dtb" ]] ||
  fail "an overlay stays out of a device tree that already has its skip-if-compatible node"
pass "a kernel device tree that has the node wins over the overlay"

# Only an available node has the compatible: Linux's of_device_is_available()
# rule is no status, "okay" or "ok"; a disabled node does not count.
dtc -q -I dts -O dtb -o "$tmp/available.dtb" - <<'DTS'
/dts-v1/;
/ {
  compatible = "apple,j293", "apple,t8103";
  none@1000 { compatible = "apple,t8103-ane"; };
  okay@1000 { compatible = "apple,t8103-ane"; status = "okay"; };
  ok@1000 { compatible = "apple,t8103-ane"; status = "ok"; };
};
DTS
dtb_overlays_has_compatible "$tmp/available.dtb" apple,t8103-ane ||
  fail "a node without status, with \"okay\" or with \"ok\" has the compatible"
for unavailable in disabled reserved; do
  dtc -q -I dts -O dtb -o "$tmp/$unavailable.dtb" - <<DTS
/dts-v1/;
/ {
  compatible = "apple,j293", "apple,t8103";
  ane@1000 { compatible = "apple,t8103-ane"; status = "$unavailable"; };
};
DTS
  ! dtb_overlays_has_compatible "$tmp/$unavailable.dtb" apple,t8103-ane ||
    fail "a \"$unavailable\" node does not have the compatible"
done
pass "only a node with no status, \"okay\" or \"ok\" has the compatible"

# A kernel that ships the node disabled does not keep the overlay out: the
# overlay merges into the node and enables it in place.
board_dtb t8103-j293-kernel-ane-disabled.dtb j293 t8103 \
  'ane@2000 { compatible = "apple,t8103-ane"; reg = <0 0x2000 0 0x100>; status = "disabled"; };'
mapfile -t result < <(dtb_overlays_apply "$tmp/out" "$dtbs/t8103-j293-kernel-ane-disabled.dtb")
[[ ${result[0]} == "$tmp/out/t8103-j293-kernel-ane-disabled.dtb" ]] ||
  fail "a disabled kernel node does not keep the overlay out: ${result[*]}"
has_ane "${result[0]}" apple,t8103-ane || fail "the overlaid tree carries the overlay's node"
[[ $(fdtget "${result[0]}" /soc/ane@2000 status) == okay ]] ||
  fail "the overlay enables the disabled node in place"
pass "a disabled kernel node does not keep the overlay out, and the overlay enables it"

rm -rf "$overlays/t8103"
overlay t8103-j293 board apple,t8103-ane
mapfile -t result < <(dtb_overlays_apply "$tmp/out" "${stock[@]}")
[[ ${result[1]} == "$dtbs/t8103-j274.dtb" && ${result[2]} == "$tmp/out/t8103-j293.dtb" ]] ||
  fail "a board prefix applies to that board only: ${result[*]}"
pass "a board prefix names one board"

overlay t6001 opt apple,t6000-ane "" /soc ane-t6001
mapfile -t result < <(dtb_overlays_apply "$tmp/out" "${stock[@]}")
[[ ${result[0]} == "$dtbs/t6001-j316c.dtb" ]] || fail "an opt-in overlay stays out until the owner opts in"
mkdir -p "$root/etc/omarchy-platform"
printf 'other\nane-t6001\n' >"$root/etc/omarchy-platform/dtb-overlays.opt-in"
mapfile -t result < <(dtb_overlays_apply "$tmp/out" "${stock[@]}")
[[ ${result[0]} == "$tmp/out/t6001-j316c.dtb" ]] ||
  fail "an opt-in overlay applies once its name is a line of /etc/omarchy-platform/dtb-overlays.opt-in"
has_ane "${result[0]}" apple,t6000-ane || fail "the opted-in overlay's node is in the device tree"
rm -f "$overlays/t6001/opt.dtbo" "$root/etc/omarchy-platform/dtb-overlays.opt-in" "$tmp/out"/*
pass "an opt-in overlay applies only after the owner opts in"

overlay t8103-j293 zz-broken apple,t8103-extra "" /soc/missing@0
rm -f "$tmp/out"/*
mapfile -t result < <(dtb_overlays_apply "$tmp/out" "${stock[@]}" 2>"$tmp/err")
[[ ${result[2]} == "$dtbs/t8103-j293.dtb" ]] || fail "a device tree an overlay does not apply to stays the kernel's"
[[ -z $(ls -A "$tmp/out") ]] || fail "a failed overlay leaves no file behind: $(ls -A "$tmp/out")"
grep -Fq "zz-broken.dtbo does not apply to t8103-j293.dtb" "$tmp/err" || fail "a failed overlay is reported: $(cat "$tmp/err")"
pass "an overlay that does not apply leaves the kernel's device tree in place"
rm -f "$overlays/t8103-j293/zz-broken.dtbo"

# update-m1n1's side: the newest kernel's device trees, in C order, with the
# overlaid copy in place of the one it replaces.
mkdir -p "$root/lib/modules/6.1.0-1-ARCH/dtbs"
rm -f "$dtbs/t8103-j293-kernel-ane.dtb" "$dtbs/t8103-j293-kernel-ane-disabled.dtb"
unset DTBS
dtb_overlays_update_m1n1
out=$root/run/omarchy-dtb-overlays
[[ $DTBS == "$dtbs/t6001-j316c.dtb $dtbs/t8103-j274.dtb $out/t8103-j293.dtb" ]] ||
  fail "update-m1n1 takes the newest kernel's device trees with the overlaid one in its place: $DTBS"
has_ane "$out/t8103-j293.dtb" apple,t8103-ane || fail "update-m1n1's copy carries the overlay"
DTBS=/custom.dtb
dtb_overlays_update_m1n1
[[ $DTBS == /custom.dtb ]] || fail "a DTBS the administrator set is kept"
unset DTBS
OMARCHY_DTB_OVERLAYS=0 dtb_overlays_update_m1n1
[[ -z ${DTBS:-} ]] || fail "OMARCHY_DTB_OVERLAYS=0 leaves DTBS alone"
sed -i 's|sort -rV|sort -r|' "$root/usr/bin/update-m1n1"
dtb_overlays_update_m1n1 2>"$tmp/err"
[[ -z ${DTBS:-} ]] || fail "an update-m1n1 with another DTBS default gets no overlays"
grep -Fq "does not reproduce" "$tmp/err" || fail "an unknown update-m1n1 is reported"
pass "update-m1n1 gets the overlaid device trees only where it reproduces the default"
