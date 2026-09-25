#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command locale

# /etc/default/update-m1n1 pins the order update-m1n1 concatenates device trees
# in, whatever locale pacman or the caller runs it under.
config=$ROOT/files/etc/default/update-m1n1
[[ -f $config ]] || fail "the package ships /etc/default/update-m1n1"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

utf8_locale=$(locale -a | grep -ixE 'en_US\.utf-?8' | head -1 || true)
if [[ -z $utf8_locale ]]; then
  mkdir -p "$tmp/locales"
  localedef -i en_US -f UTF-8 "$tmp/locales/en_US.UTF-8" 2>/dev/null ||
    fail "an en_US.UTF-8 locale is available or can be compiled for the collation fixture"
  export LOCPATH="$tmp/locales"
  utf8_locale=en_US.UTF-8
fi

dtbs=$tmp/dtbs
mkdir -p "$dtbs"
names=(t6000-j314s.dtb t8103-j293.dtb t8103_j274.dtb)
for name in "${names[@]}"; do
  printf '%s\n' "$name" >"$dtbs/$name"
done
c_order=$(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
utf8_order=$(printf '%s\n' "${names[@]}" | LC_ALL=$utf8_locale sort)
[[ $c_order != "$utf8_order" ]] || fail "the fixture's device trees sort differently in C and $utf8_locale"

# update-m1n1's own steps, as /bin/sh: source the defaults file when present,
# fill DTBS, then concatenate the unquoted glob. Arguments are the defaults
# file (or nothing) and the caller's locale environment.
update_m1n1_order() {
  local defaults=$1
  shift
  env "$@" sh -c '
    [ -z "$1" ] || . "$1"
    : ${DTBS:="$2/*.dtb"}
    cat $DTBS
  ' _ "$defaults" "$dtbs"
}

[[ $(update_m1n1_order "" -u LC_ALL -u LC_COLLATE LANG="$utf8_locale") == "$utf8_order" ]] ||
  fail "without the defaults file, update-m1n1 follows the caller's collation"
[[ $(update_m1n1_order "$config" -u LC_ALL -u LC_COLLATE LANG="$utf8_locale") == "$c_order" ]] ||
  fail "with the defaults file, a $utf8_locale LANG still concatenates in C order"
[[ $(update_m1n1_order "$config" -u LC_COLLATE LC_ALL="$utf8_locale") == "$c_order" ]] ||
  fail "with the defaults file, a $utf8_locale LC_ALL still concatenates in C order"
pass "update-m1n1 concatenates device trees in C order under any caller locale"

# The file only sets the locale: every input update-m1n1 and the boot check
# read from it keeps its default.
set_by_config=$(env -i PATH=/usr/bin:/bin bash --noprofile --norc -c '
  unset DTBS SOURCE M1N1 U_BOOT CONFIG TARGET M1N1_UPDATE_DISABLED
  . "$1" >/dev/null 2>&1 || exit 1
  for name in DTBS SOURCE M1N1 U_BOOT CONFIG TARGET M1N1_UPDATE_DISABLED; do
    [ -z "${!name+x}" ] || echo "$name"
  done
' _ "$config") || fail "the defaults file sources cleanly"
[[ -z $set_by_config ]] || fail "the defaults file leaves update-m1n1's inputs at their defaults (sets: $set_by_config)"
pass "the defaults file sets no update-m1n1 input"
