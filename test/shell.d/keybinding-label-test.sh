#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

compatible="$tmp_dir/compatible"
model="$tmp_dir/model"
helper="$ROOT/bin/omarchy-keybinding-label"

printf 'apple,j313\0apple,t8103\0' >"$compatible"
printf 'Apple MacBook Air (M1, 2020)\0' >"$model"

label() {
  OMARCHY_PATH="$ROOT" \
    OMARCHY_UNAME_M=aarch64 \
    OMARCHY_APPLE_COMPATIBLE="$compatible" \
    OMARCHY_APPLE_MODEL="$model" \
    "$helper" "$@"
}

[[ $(label 'Super + Alt + Ctrl + ,') == 'Command + Option + Control + ,' ]] ||
  fail "M1 Air labels use the physical modifier names"
[[ $(label 'Super + Alt + ,') == 'Command + Option + ,' ]] ||
  fail "M1 Air capture notifications name Command+Option"
[[ $(label 'SUPER + ALT + CTRL + K') == 'COMMAND + OPTION + CONTROL + K' ]] ||
  fail "M1 Air labels preserve the caller's capitalization"
[[ $(label 'Super+K, Alt+F4, and Ctrl+X') == 'Command+K, Option+F4, and Control+X' ]] ||
  fail "M1 Air labels support compact shortcuts and punctuation"
pass "M1 Air labels use Command, Option, and Control"

[[ $(label 'Superman chose Alternative controls and AltGr') == 'Superman chose Alternative controls and AltGr' ]] ||
  fail "key names embedded in prose words are not rewritten"
pass "hardware-aware labels only replace complete key names"

[[ $(label --embedded 'Super results; use Super + K or Ctrl+X') == 'Super results; use Command + K or Control+X' ]] ||
  fail "embedded labels only rewrite shortcut-shaped text"
[[ $(label --embedded 'C++ Super Resolution; A + Alt text') == 'C++ Super Resolution; A + Alt text' ]] ||
  fail "plus signs before prose are not mistaken for shortcut modifiers"
pass "embedded label conversion leaves standalone prose intact"

[[ $(label --m1-air 'F5' 'F9') == 'F5' ]] ||
  fail "the M1 Air dictation hint names its physical F5 key"
[[ $(label --m1-air 'Command + F12' 'Print') == 'Command + F12' ]] ||
  fail "the M1 Air screenshot hint replaces the unavailable Print key"
[[ $(label --m1-air 'Command + Option + F12' 'Alt + Print') == 'Command + Option + F12' ]] ||
  fail "the M1 Air screen-recording hint replaces the unavailable Print chord"
pass "M1 Air labels support explicit top-row and capture mappings"

printf 'Apple MacBook Pro (13-inch, M1, 2020)\0' >"$model"
[[ $(label 'Super + Alt + Ctrl + ,') == 'Super + Alt + Ctrl + ,' ]] ||
  fail "another Mac retains the existing modifier wording"
[[ $(label 'Super + Alt + ,') == 'Super + Alt + ,' ]] ||
  fail "another Mac retains the existing capture notification wording"
[[ $(label --m1-air 'F5' 'F9') == 'F9' ]] ||
  fail "another Mac retains the existing dictation key"
[[ $(label --m1-air 'Command + F12' 'Print') == 'Print' ]] ||
  fail "another Mac retains the existing screenshot key"
pass "non-M1 systems retain their existing shortcut wording"

notification_files=(
  bin/omarchy-capture-screenrecording
  bin/omarchy-capture-screenshot
  bin/omarchy-games-retro-install
  bin/omarchy-hyprland-window-width
  bin/omarchy-voxtype-install
  install/user/first-run/welcome.sh
)

for file in "${notification_files[@]}"; do
  grep -Fq 'omarchy-keybinding-label' "$ROOT/$file" ||
    fail "shortcut-bearing notification uses the shared label helper" "$file"
done

grep -Fq 'headline=$("$OMARCHY_PATH/bin/omarchy-keybinding-label" --embedded "$headline")' "$ROOT/bin/omarchy-notification-send" ||
  fail "the notification sender normalizes headline labels centrally"
grep -Fq 'description=$("$OMARCHY_PATH/bin/omarchy-keybinding-label" --embedded "$description")' "$ROOT/bin/omarchy-notification-send" ||
  fail "the notification sender normalizes body labels centrally"

grep -Fq '"Edit with $notification_shortcut (or click this)"' "$ROOT/bin/omarchy-capture-screenshot" ||
  fail "the screenshot notification uses its hardware-aware shortcut"
grep -Fq '"Open with $notification_shortcut (or click this)"' "$ROOT/bin/omarchy-capture-screenrecording" ||
  fail "the screen-recording notification uses its hardware-aware shortcut"
grep -Fq '"Start it with $menu_shortcut"' "$ROOT/bin/omarchy-games-retro-install" ||
  fail "the retro-game notification uses its hardware-aware shortcut"
grep -Fq '"Use $save_shortcut to save one for this workspace."' "$ROOT/bin/omarchy-hyprland-window-width" ||
  fail "the window-width save notification uses its hardware-aware shortcut"
grep -Fq '"Restore using $restore_shortcut on this workspace."' "$ROOT/bin/omarchy-hyprland-window-width" ||
  fail "the window-width restore notification uses its hardware-aware shortcut"
grep -Fq '"$dictation_hint"' "$ROOT/bin/omarchy-voxtype-install" ||
  fail "the Voxtype notification uses its hardware-aware shortcut"
grep -Fq '"$keybindings_shortcut for cheatsheet."' "$ROOT/install/user/first-run/welcome.sh" ||
  fail "the welcome notification uses its hardware-aware cheatsheet shortcut"
grep -Fq '"$menu_shortcut for Omarchy Menu."' "$ROOT/install/user/first-run/welcome.sh" ||
  fail "the welcome notification uses its hardware-aware menu shortcut"

if rg -n 'omarchy-notification-send.*(Super|Alt|Ctrl|Print|F9)' "${notification_files[@]/#/$ROOT/}"; then
  fail "notification calls do not embed hardware-specific shortcut names"
fi
pass "shortcut-bearing notifications use hardware-aware labels"

notification_log="$tmp_dir/notification"
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >"$OMARCHY_TEST_NOTIFICATION_LOG"
SH
chmod +x "$stub_bin/omarchy-notification-send"

printf 'Apple MacBook Air (M1, 2020)\0' >"$model"
OMARCHY_PATH="$ROOT" \
  OMARCHY_UNAME_M=aarch64 \
  OMARCHY_APPLE_COMPATIBLE="$compatible" \
  OMARCHY_APPLE_MODEL="$model" \
  OMARCHY_TEST_NOTIFICATION_LOG="$notification_log" \
  PATH="$stub_bin:$ROOT/bin:$PATH" \
  bash "$ROOT/install/user/first-run/welcome.sh"

grep -Fq 'Command + K for cheatsheet.' "$notification_log" ||
  fail "the M1 Air welcome notification names Command+K"
grep -Fq 'Command + Space for Omarchy Menu.' "$notification_log" ||
  fail "the M1 Air welcome notification names Command+Space"
pass "the M1 Air welcome notification uses physical modifier names"

printf 'Apple MacBook Pro (13-inch, M1, 2020)\0' >"$model"
OMARCHY_PATH="$ROOT" \
  OMARCHY_UNAME_M=aarch64 \
  OMARCHY_APPLE_COMPATIBLE="$compatible" \
  OMARCHY_APPLE_MODEL="$model" \
  OMARCHY_TEST_NOTIFICATION_LOG="$notification_log" \
  PATH="$stub_bin:$ROOT/bin:$PATH" \
  bash "$ROOT/install/user/first-run/welcome.sh"

grep -Fq 'Super + K for cheatsheet.' "$notification_log" ||
  fail "another Mac keeps Super+K in the welcome notification"
grep -Fq 'Super + Space for Omarchy Menu.' "$notification_log" ||
  fail "another Mac keeps Super+Space in the welcome notification"
pass "the non-M1 welcome notification retains its wording"
