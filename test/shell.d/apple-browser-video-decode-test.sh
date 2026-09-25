#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/user/hardware/apple/browser-video-decode.sh"
migration=$(grep -rl 'Turn off hardware video decode in Chromium-family browsers on Apple Silicon' "$ROOT/migrations" | head -n 1 || true)
flag="--disable-features=AcceleratedVideoDecoder"

[[ -f $leaf ]] || fail "the Apple Silicon browser video decode leaf ships"
grep -Fq 'user/hardware/apple/browser-video-decode.sh' "$ROOT/install/user/all.sh" ||
  fail "fresh installs run the browser video decode leaf for each user"
[[ -n $migration ]] || fail "existing installs get the browser video decode workaround"
! grep -Fq 'AcceleratedVideoDecoder' "$ROOT/config/chromium-flags.conf" ||
  fail "shipped Chromium flags keep hardware decode on for x86 and other ARM"
pass "fresh installs, existing installs and new browsers are wired to the Apple browser decode workaround"

require_platform_fixtures "the browser video decode platform gates"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
home="$test_tmp/home"
for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$test_tmp/$platform" "$platform"
done

# $1 is the platform, $2 the script, $3 how to run it.
run_on() {
  local platform="$1" script="$2" mode="${3:-source}" fixture="$test_tmp/$1"
  if [[ $mode == "source" ]]; then
    HOME="$home" OMARCHY_PATH="$ROOT" OMARCHY_PROC_ROOT="$fixture/proc" PATH="$fixture/bin:$ROOT/bin:$PATH" \
      bash -euo pipefail -c 'source "$1"' _ "$script" >/dev/null
  else
    HOME="$home" OMARCHY_PATH="$ROOT" OMARCHY_PROC_ROOT="$fixture/proc" PATH="$fixture/bin:$ROOT/bin:$PATH" \
      bash -euo pipefail "$script" >/dev/null
  fi
}

conf="$home/.config/brave-flags.conf"
mkdir -p "$home/.config"

for platform in qualcomm generic-aarch64 generic; do
  printf '%s\n' '--ozone-platform=wayland' '--disable-features=SomeOtherThing' >"$conf"
  before=$(<"$conf")
  run_on "$platform" "$leaf"
  run_on "$platform" "$migration" run
  [[ $(<"$conf") == "$before" ]] ||
    fail "browser video decode stays on for $platform" "$(cat "$conf")"
done
pass "x86, Qualcomm and other ARM keep browser hardware decode"

printf '%s\n' '--ozone-platform=wayland' >"$conf"
run_on apple-silicon "$leaf"
grep -Fxq -- "$flag" "$conf" || fail "a plain flags file gets the decode workaround" "$(cat "$conf")"
pass "a plain flags file gets the decode workaround"

printf '%s' '--ozone-platform=wayland' >"$conf"
run_on apple-silicon "$leaf"
[[ $(<"$conf") == $'--ozone-platform=wayland\n--disable-features=AcceleratedVideoDecoder' ]] ||
  fail "the workaround goes on its own line when the file lacks a final newline" "$(cat "$conf")"
pass "the workaround goes on its own line when the file lacks a final newline"

printf '%s\n' '--disable-features=SomeOtherThing' '--ozone-platform=wayland' >"$conf"
run_on apple-silicon "$migration" run
[[ $(<"$conf") == $'--disable-features=SomeOtherThing,AcceleratedVideoDecoder\n--ozone-platform=wayland' ]] ||
  fail "the workaround joins an existing disable-features list" "$(cat "$conf")"
(( $(grep -c -- '^--disable-features=' "$conf") == 1 )) ||
  fail "the workaround never adds a second disable-features argument" "$(cat "$conf")"
pass "the workaround joins an existing disable-features list"

printf '%s\n' '--disable-features=One' '--disable-features=Two  ' $'--disable-features=Three\r' >"$conf"
run_on apple-silicon "$leaf"
[[ $(<"$conf") == $'--disable-features=One,AcceleratedVideoDecoder\n--disable-features=Two,AcceleratedVideoDecoder  \n--disable-features=Three,AcceleratedVideoDecoder\r' ]] ||
  fail "every disable-features line gets the feature before trailing whitespace" "$(cat -A "$conf")"
pass "every disable-features line gets the feature before trailing whitespace"

printf '%s\n' '--disable-features=' >"$conf"
run_on apple-silicon "$leaf"
grep -Fxq -- "$flag" "$conf" || fail "an empty disable-features list takes the feature alone" "$(cat "$conf")"
pass "an empty disable-features list takes the feature alone"

printf '%s\n' '--disable-features=AcceleratedVideoDecoder,SomeOtherThing' >"$conf"
before=$(<"$conf")
run_on apple-silicon "$leaf"
run_on apple-silicon "$migration" run
[[ $(<"$conf") == "$before" ]] || fail "an already disabled decoder is left alone" "$(cat "$conf")"

printf '%s\n' '--disable-features=AcceleratedVideoDecoderExtra' >"$conf"
run_on apple-silicon "$leaf"
run_on apple-silicon "$leaf"
[[ $(<"$conf") == '--disable-features=AcceleratedVideoDecoderExtra,AcceleratedVideoDecoder' ]] ||
  fail "only the exact feature name counts as already disabled" "$(cat "$conf")"
pass "reruns are idempotent and match the exact feature name"

rm -f "$conf"
for browser in chromium chrome microsoft-edge-stable brave brave-origin; do
  printf '%s\n' '--ozone-platform=wayland' >"$home/.config/$browser-flags.conf"
done
printf '%s\n' '--ozone-platform=wayland' >"$home/.config/electron-flags.conf"
run_on apple-silicon "$migration" run
for browser in chromium chrome microsoft-edge-stable brave brave-origin; do
  grep -Fxq -- "$flag" "$home/.config/$browser-flags.conf" ||
    fail "the migration covers $browser" "$(cat "$home/.config/$browser-flags.conf")"
done
! grep -Fq 'AcceleratedVideoDecoder' "$home/.config/electron-flags.conf" ||
  fail "the migration leaves Electron flags alone"
pass "the migration covers every browser omarchy-install-browser configures"

rm -f "$home"/.config/*-flags.conf
run_on apple-silicon "$migration" run || fail "the migration no-ops without browser flags files"
[[ -z $(find "$home/.config" -name '*-flags.conf') ]] || fail "the migration creates no flags files"
pass "the migration no-ops without browser flags files"

# omarchy-install-browser rewrites the flags file from the shipped defaults, so
# a browser installed later must get the workaround at that point.
copy_flags=$(sed -n '/^copy_chromium_flags() {/,/^}/p' "$ROOT/bin/omarchy-install-browser")
[[ -n $copy_flags ]] || fail "omarchy-install-browser defines copy_chromium_flags"
install_browser_flags() {
  local fixture="$test_tmp/$1"
  HOME="$home" OMARCHY_PATH="$ROOT" OMARCHY_PROC_ROOT="$fixture/proc" PATH="$fixture/bin:$ROOT/bin:$PATH" \
    bash -euo pipefail -c '
      helpers=$3
      omarchy-install-chromium-copy-url() { echo copy-url >>"$helpers"; }
      omarchy-install-chromium-ytdlp() { echo ytdlp >>"$helpers"; }
      eval "$1"
      copy_chromium_flags "$2"
    ' _ "$copy_flags" "$conf" "$helpers"
}
helpers="$test_tmp/helpers.log"

: >"$helpers"
install_browser_flags generic
cmp -s "$ROOT/config/chromium-flags.conf" "$conf" ||
  fail "a browser installed on x86 gets the shipped flags unchanged" "$(cat "$conf")"
install_browser_flags qualcomm
cmp -s "$ROOT/config/chromium-flags.conf" "$conf" ||
  fail "a browser installed on Qualcomm gets the shipped flags unchanged" "$(cat "$conf")"
install_browser_flags apple-silicon
grep -Fxq -- "$flag" "$conf" || fail "a browser installed on Apple Silicon gets the decode workaround" "$(cat "$conf")"
[[ $(<"$helpers") == $'copy-url\nytdlp\ncopy-url\nytdlp\ncopy-url\nytdlp' ]] ||
  fail "the browser install still sets up the extension helpers after the workaround" "$(cat "$helpers")"
pass "a browser installed later gets the workaround only on Apple Silicon"
