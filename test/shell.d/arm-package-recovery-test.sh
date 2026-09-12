#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

recovery="$ROOT/fix-arm-packages.sh"

[[ -x $recovery ]] || fail 'recovery script is executable'
bash -n "$recovery" || fail 'recovery script parses'
pass 'recovery script is present, executable, and parses'

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

conf="$test_tmp/pacman.conf"
printf '%s\n' '[options]' 'Architecture = aarch64' '[extra]' 'Server = https://regular.example/$arch' '[omarchy-aarch64]' 'Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/channel-stable' > "$conf"
cp "$conf" "$test_tmp/original"

run_recovery() {
  OMARCHY_ARM_PACMAN_CONF="$conf" bash "$recovery" "$@" 2>&1
}

output=$(run_recovery --dry-run) || fail 'dry run succeeds' "$output"

cmp -s "$test_tmp/original" "$conf" || fail 'dry run leaves the configuration untouched'
[[ ! -e "$conf.bak" ]] || fail 'dry run writes no backup'
pass 'dry run changes nothing on the machine'

grep -q '^+\[omarchy\]$' <<<"$output" || fail 'dry run adds the edge section' "$output"
grep -q '^+Usage = Sync$' <<<"$output" || fail 'dry run keeps edge out of automatic selection' "$output"
grep -q '^+SigLevel = Required DatabaseOptional$' <<<"$output" || fail 'dry run requires signed packages' "$output"
grep -q 'would run: sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu --noconfirm omarchy/hyprland omarchy/hyprtoolkit omarchy/hyprland-guiutils' <<<"$output" ||
  fail 'dry run reports the selected packages' "$output"
grep -q 'would run: sudo pacman-key' <<<"$output" || fail 'dry run reports the key import' "$output"
pass 'dry run reports the restricted signed edge section and the transaction'

# The update guard hook aborts any direct -Syu that does not identify itself,
# so a recovery that forgets this never reaches the packages it exists to
# install. The reported command must be the one that runs, or the dry run
# hides the failure instead of predicting it.
guard="$ROOT/bin/omarchy-update-pacman-guard"
if [[ -f $guard ]]; then
  grep -q 'OMARCHY_UPDATE_PACMAN' "$guard" || fail 'the guard still reads OMARCHY_UPDATE_PACMAN'
fi
transaction=$(grep -n 'pacman -Syu --noconfirm "\${targets\[@\]}"' "$recovery") || fail 'recovery runs the selection'
[[ $transaction == *'sudo env OMARCHY_UPDATE_PACMAN=1 pacman'* ]] ||
  fail 'the transaction identifies itself to the update guard' "$transaction"
reported=$(grep -o 'would run: sudo env [^"]*pacman -Syu --noconfirm' <<<"$output")
[[ $reported == "would run: sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu --noconfirm" ]] ||
  fail 'the reported transaction matches the one that runs' "$reported"
pass 'the transaction identifies itself to the update guard'

grep -q 'Server = https://regular.example' <<<"$(cat "$conf")" || fail 'regular mirrors kept'
grep -q '^+Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/channel-stable$' <<<"$output" || fail 'recovery preserves the selected stable channel' "$output"
pass 'recovery only adds to a configuration that has no edge section'

# This script exists for machines whose installed package predates the helper,
# so a checkout must never be the only place it can find one. Point every local
# candidate at an empty directory and let it fall back to the published copy,
# served from a file here so the test needs no network.
cp "$ROOT/install/helpers/arm-package-sources.sh" "$test_tmp/published-helper.sh"
cp "$ROOT/install/helpers/arm-channel-manifest.py" "$test_tmp/arm-channel-manifest.py"
mkdir -p "$test_tmp/empty"
cp "$recovery" "$test_tmp/empty/fix-arm-packages.sh"
cp "$test_tmp/original" "$conf"
download_tmp="$test_tmp/downloads"
mkdir -p "$download_tmp"

output=$(
  TMPDIR="$download_tmp" \
  OMARCHY_ARM_PACMAN_CONF="$conf" \
    OMARCHY_PATH="$test_tmp/empty" \
    OMARCHY_ARM_HELPER_URL="file://$test_tmp/published-helper.sh" \
    bash "$test_tmp/empty/fix-arm-packages.sh" --dry-run 2>&1
) || fail 'dry run without a local helper succeeds' "$output"
grep -q 'omarchy/hyprland omarchy/hyprtoolkit omarchy/hyprland-guiutils' <<<"$output" ||
  fail 'fetched helper supplies the selected packages' "$output"
[[ -z $(find "$download_tmp" -mindepth 1 -print -quit) ]] ||
  fail 'fetched helper is removed after use' "$(find "$download_tmp" -mindepth 1 -maxdepth 1 -printf '%f\n')"
pass 'recovery falls back to the published helper when no checkout is installed'

# The documented pipe puts the script itself on stdin. A pacman invocation
# that asks questions can consume the rest of that script as answers. Run the
# real recovery through that pipe and make the pacman stub fail after two
# prompts unless the transaction explicitly disables prompting.
stub_bin="$test_tmp/stub-bin"
call_log="$test_tmp/calls"
mkdir -p "$stub_bin"
cat > "$stub_bin/python3" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$stub_bin/python3"
cat > "$stub_bin/uname" <<'STUB'
#!/bin/bash
printf '%s\n' aarch64
STUB
cat > "$stub_bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB
cat > "$stub_bin/pacman-key" <<'STUB'
#!/bin/bash
if [[ $1 == "--list-keys" ]]; then
  exit 1
fi
exit 0
STUB
cat > "$stub_bin/pacman" <<'STUB'
#!/bin/bash
printf 'pacman' >> "$OMARCHY_TEST_CALL_LOG"
printf '\t%s' "$@" >> "$OMARCHY_TEST_CALL_LOG"
printf '\n' >> "$OMARCHY_TEST_CALL_LOG"
if [[ " $* " != *" --noconfirm "* ]]; then
  printf 'Replace package? [Y/n] ' >&2
  IFS= read -r first_answer || true
  printf 'Select provider? [1] ' >&2
  IFS= read -r second_answer || true
  printf 'answers\t%s\t%s\n' "$first_answer" "$second_answer" >> "$OMARCHY_TEST_CALL_LOG"
  exit 42
fi
STUB
chmod +x "$stub_bin/uname" "$stub_bin/sudo" "$stub_bin/pacman-key" "$stub_bin/pacman"

cp "$test_tmp/original" "$conf"
rm -f "$conf.bak" "$call_log"
pipe_tmp="$test_tmp/pipe-downloads"
mkdir -p "$pipe_tmp"
output=$(
  cat "$test_tmp/empty/fix-arm-packages.sh" | env \
    PATH="$stub_bin:$PATH" \
    TMPDIR="$pipe_tmp" \
    OMARCHY_ARM_PACMAN_CONF="$conf" \
    OMARCHY_PATH="$test_tmp/empty" \
    OMARCHY_ARM_HELPER_URL="file://$test_tmp/published-helper.sh" \
    OMARCHY_TEST_CALL_LOG="$call_log" \
    bash -s -- --no-snapshot 2>&1
) || fail 'piped recovery succeeds without reading script text as prompt answers' "$output"
grep -q $'^pacman\t-Syu\t--noconfirm\tomarchy/hyprland\tomarchy/hyprtoolkit\tomarchy/hyprland-guiutils$' "$call_log" ||
  fail 'piped recovery runs the noninteractive package transaction' "$(cat "$call_log")"
! grep -q '^answers' "$call_log" || fail 'piped recovery lets pacman prompt on script input' "$(cat "$call_log")"
grep -q '^\[omarchy\]$' "$conf" || fail 'piped recovery prepares the package source' "$(cat "$conf")"
[[ -f "$conf.bak" ]] || fail 'piped recovery backs up the package configuration'
[[ -z $(find "$pipe_tmp" -mindepth 1 -print -quit) ]] ||
  fail 'piped recovery cleans its downloaded helper' "$(find "$pipe_tmp" -mindepth 1 -maxdepth 1 -printf '%f\n')"
pass 'documented pipe runs the complete recovery without interactive package prompts'

cp "$test_tmp/original" "$conf"
output=$(run_recovery --unknown-option && echo UNEXPECTED) || true
grep -q 'Unknown option' <<<"$output" || fail 'unknown options are rejected' "$output"
! grep -q UNEXPECTED <<<"$output" || fail 'unknown options do not run the recovery' "$output"
cmp -s "$test_tmp/original" "$conf" || fail 'a rejected invocation changes nothing'
pass 'unknown options are rejected before anything runs'
