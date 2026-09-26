#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# pacman's systemd hook runs this after installing or upgrading the package.
tmpfiles() { systemd-tmpfiles --create --root="$1" || fail "systemd-tmpfiles applies the package rules in $1"; }
setting() { sed -n "s/^$2=//p" "$1/etc/mpv/mpv.conf"; }

"$ROOT"/install "$work/fresh"
tmpfiles "$work/fresh"
cmp -s "$work/fresh/etc/mpv/mpv.conf" "$work/fresh/usr/share/omarchy-mac/mpv/mpv.conf" ||
  fail 'a fresh install gets the vendor mpv default'
[[ $(setting "$work/fresh" hwdec) == "vaapi-copy" ]] ||
  fail 'mpv decodes on AVD with copy-back, never zero-copy' "$(setting "$work/fresh" hwdec)"
[[ $(setting "$work/fresh" hwdec-codecs) == "h264,hevc,vp9" ]] ||
  fail 'mpv asks AVD only for the codecs it decodes' "$(setting "$work/fresh" hwdec-codecs)"
[[ $(setting "$work/fresh" vo) == "gpu" && $(setting "$work/fresh" gpu-api) == "opengl" ]] ||
  fail 'mpv draws copied frames with the OpenGL renderer'
pass 'a fresh install decodes H.264, HEVC and VP9 on AVD in mpv, with copy-back and OpenGL'

# An upgraded Mac already has /etc/mpv from mpv-mpris.
"$ROOT"/install "$work/upgrade"
mkdir -p "$work/upgrade/etc/mpv/scripts"
ln -s /usr/lib/mpv-mpris/mpris.so "$work/upgrade/etc/mpv/scripts/mpris.so"
tmpfiles "$work/upgrade"
[[ $(setting "$work/upgrade" hwdec) == "vaapi-copy" ]] || fail 'an upgrade adds the mpv default'
[[ -L $work/upgrade/etc/mpv/scripts/mpris.so ]] || fail 'an upgrade leaves mpv scripts alone'
pass 'an upgraded install gets the mpv default beside its scripts'

"$ROOT"/install "$work/admin"
mkdir -p "$work/admin/etc/mpv"
printf 'hwdec=no\nprofile=gpu-hq\n' >"$work/admin/etc/mpv/mpv.conf"
tmpfiles "$work/admin"
[[ $(<"$work/admin/etc/mpv/mpv.conf") == $'hwdec=no\nprofile=gpu-hq' ]] ||
  fail 'an administrator mpv.conf stays' "$(<"$work/admin/etc/mpv/mpv.conf")"
printf 'hwdec=no\n' >"$work/fresh/etc/mpv/mpv.conf"
tmpfiles "$work/fresh"
[[ $(setting "$work/fresh" hwdec) == "no" ]] || fail 'a later edit survives the next upgrade'
pass 'an administrator mpv.conf, or a later edit, is never overwritten'
