#!/bin/bash

# omarchy-system-btrfs-migrate stages a boot that prompts for the disk
# passphrase on /dev/console. On Apple Silicon that is the serial port unless
# the kernel command line says console=tty0, so the staging step writes it into
# GRUB's defaults and regenerates grub.cfg. These checks run the function
# against fixture files: no root, no disk, no real grub-mkconfig.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf 'apple,j375c\0apple,t6001\0apple,arm-platform\0' >"$work/apple"
printf 'raspberrypi,5-model-b\0brcm,bcm2712\0' >"$work/pi"

# Runs ensure_display_console in a subshell with the fixtures in place of the
# device tree and /etc/default/grub, and grub-mkconfig replaced by a recorder.
run_fixture() (
  local compatible=$1 grub=$2
  source "$ROOT/bin/omarchy-system-btrfs-migrate"
  grub-mkconfig() { printf '%s\n' "$*" >>"$work/mkconfig"; }
  log() { :; }
  warn() { printf '%s\n' "$*" >>"$work/warnings"; }
  fail() { printf '%s\n' "$*" >>"$work/errors"; exit 1; }
  OMARCHY_APPLE_COMPATIBLE=$compatible OMARCHY_GRUB_DEFAULT=$grub ensure_display_console
)

mkconfig_calls() {
  if [[ -f $work/mkconfig ]]; then wc -l <"$work/mkconfig"; else echo 0; fi
}

# The Asahi Alarm default: quiet, no console named.
cat >"$work/asahi" <<'GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"
GRUB_CMDLINE_LINUX=""
GRUB

run_fixture "$work/apple" "$work/asahi"
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet console=tty0"' "$work/asahi" ||
  fail 'console=tty0 is appended to the default command line' "$(cat "$work/asahi")"
grep -qx 'GRUB_CMDLINE_LINUX=""' "$work/asahi" || fail 'GRUB_CMDLINE_LINUX is left alone'
[[ $(mkconfig_calls) == 1 ]] || fail 'grub.cfg is regenerated once'
grep -qx -- '-o /boot/grub/grub.cfg' "$work/mkconfig" || fail 'grub.cfg is written where GRUB reads it'
pass 'an Apple Silicon machine with no console gets console=tty0 and a new grub.cfg'

cp "$work/asahi" "$work/expected"
run_fixture "$work/apple" "$work/asahi"
cmp -s "$work/asahi" "$work/expected" || fail 'a second run changes nothing' "$(diff "$work/expected" "$work/asahi")"
[[ $(mkconfig_calls) == 1 ]] || fail 'a second run does not regenerate grub.cfg'
pass 'the change is idempotent'

printf "GRUB_CMDLINE_LINUX_DEFAULT='loglevel=3 quiet'\n" >"$work/single"
run_fixture "$work/apple" "$work/single"
grep -qx "GRUB_CMDLINE_LINUX_DEFAULT='loglevel=3 quiet console=tty0'" "$work/single" ||
  fail 'single-quoted values are appended inside their quotes' "$(cat "$work/single")"
pass 'single quotes are respected'

printf 'GRUB_CMDLINE_LINUX_DEFAULT=""\n' >"$work/empty"
run_fixture "$work/apple" "$work/empty"
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty0"' "$work/empty" ||
  fail 'an empty value gets console=tty0 without a leading space' "$(cat "$work/empty")"
pass 'an empty command line is handled'

printf 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"  # keep it quiet\n' >"$work/comment"
run_fixture "$work/apple" "$work/comment"
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet console=tty0"  # keep it quiet' "$work/comment" ||
  fail 'a trailing comment is kept' "$(cat "$work/comment")"
pass 'a trailing comment survives'

rm -f "$work/mkconfig"
printf 'GRUB_CMDLINE_LINUX_DEFAULT=$UNQUOTED\n' >"$work/odd"
run_fixture "$work/apple" "$work/odd" || fail 'a value the edit cannot parse does not abort the staging'
grep -q 'add it yourself' "$work/warnings" || fail 'a value the edit cannot parse is warned about'
[[ $(mkconfig_calls) == 0 ]] || fail 'nothing is regenerated when nothing was added'
pass 'an unparseable value warns instead of regenerating a config without the fix'

printf 'GRUB_TIMEOUT=5\n' >"$work/absent"
run_fixture "$work/apple" "$work/absent"
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty0"' "$work/absent" ||
  fail 'a file without the variable gains it' "$(cat "$work/absent")"
pass 'a missing GRUB_CMDLINE_LINUX_DEFAULT is added'

rm -f "$work/mkconfig"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet console=ttySAC0,115200"\n' >"$work/serial"
cp "$work/serial" "$work/serial.expected"
run_fixture "$work/apple" "$work/serial"
cmp -s "$work/serial" "$work/serial.expected" || fail 'a console the owner chose is kept' "$(cat "$work/serial")"
[[ $(mkconfig_calls) == 0 ]] || fail 'no grub.cfg churn when nothing changed'
pass 'an explicit serial console is left alone'

printf 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"\nGRUB_CMDLINE_LINUX="console=tty0"\n' >"$work/linux-var"
cp "$work/linux-var" "$work/linux-var.expected"
run_fixture "$work/apple" "$work/linux-var"
cmp -s "$work/linux-var" "$work/linux-var.expected" || fail 'a console set in GRUB_CMDLINE_LINUX counts' "$(cat "$work/linux-var")"
pass 'a console on either GRUB variable satisfies the check'

printf 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"\n' >"$work/pi-grub"
cp "$work/pi-grub" "$work/pi-grub.expected"
run_fixture "$work/pi" "$work/pi-grub"
cmp -s "$work/pi-grub" "$work/pi-grub.expected" || fail 'a non-Apple machine is untouched' "$(cat "$work/pi-grub")"
[[ $(mkconfig_calls) == 0 ]] || fail 'a non-Apple machine does not regenerate grub.cfg'
pass 'only Apple Silicon is affected'

run_fixture "$work/apple" "$work/does-not-exist" || fail 'a missing /etc/default/grub does not abort the staging'
[[ -f $work/warnings ]] && grep -q 'console=tty0' "$work/warnings" || fail 'a missing /etc/default/grub is warned about'
[[ $(mkconfig_calls) == 0 ]] || fail 'nothing is regenerated without a defaults file'
pass 'a missing GRUB defaults file warns instead of failing'

# The value ends at its closing quote, not at the last quote on the line.
printf 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet" # say "hello"\n' >"$work/quoted-comment"
run_fixture "$work/apple" "$work/quoted-comment"
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet console=tty0" # say "hello"' "$work/quoted-comment" ||
  fail 'console=tty0 goes inside the value, not inside a quoted comment' "$(cat "$work/quoted-comment")"
pass 'a trailing comment with quotes of its own does not capture the edit'

# A \" inside the value is part of it, not its end. The edited file must still
# read as grub-mkconfig reads it, by sourcing it.
rm -f "$work/mkconfig"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet dyndbg=\\"file drivers/usb/* +p\\""\n' >"$work/escaped"
run_fixture "$work/apple" "$work/escaped"
grep -qxF 'GRUB_CMDLINE_LINUX_DEFAULT="quiet dyndbg=\"file drivers/usb/* +p\" console=tty0"' "$work/escaped" ||
  fail 'console=tty0 goes after an escaped quote, not before it' "$(cat "$work/escaped")"
[[ $(. "$work/escaped"; printf '%s' "$GRUB_CMDLINE_LINUX_DEFAULT") == 'quiet dyndbg="file drivers/usb/* +p" console=tty0' ]] ||
  fail 'the edited file still reads as the shell reads it' "$(cat "$work/escaped")"
[[ $(mkconfig_calls) == 1 ]] || fail 'grub.cfg is regenerated for a value with escaped quotes'
pass 'a value with escaped quotes keeps its quoting'

rm -f "$work/mkconfig"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="dyndbg=\\"file drivers/usb/* +p\\" console=ttySAC0,115200"\n' >"$work/escaped-serial"
cp "$work/escaped-serial" "$work/escaped-serial.expected"
run_fixture "$work/apple" "$work/escaped-serial"
cmp -s "$work/escaped-serial" "$work/escaped-serial.expected" || fail 'a console after an escaped quote is seen' "$(cat "$work/escaped-serial")"
[[ $(mkconfig_calls) == 0 ]] || fail 'no grub.cfg churn when the console was there all along'
pass 'a console set after an escaped quote counts'

# A comment is not a console.
rm -f "$work/mkconfig"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet" # console=ttySAC0 was tried once\n' >"$work/commented-console"
run_fixture "$work/apple" "$work/commented-console"
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet console=tty0" # console=ttySAC0 was tried once' "$work/commented-console" ||
  fail 'a console= inside a comment does not count as a console' "$(cat "$work/commented-console")"
[[ $(mkconfig_calls) == 1 ]] || fail 'grub.cfg is regenerated when the only console= was in a comment'
pass 'a console named only in a comment is still fixed'

printf 'GRUB_CMDLINE_LINUX_DEFAULT=loglevel=3\n' >"$work/bare"
cp "$work/bare" "$work/bare.expected"
run_fixture "$work/apple" "$work/bare" || fail 'an unquoted value does not abort the staging'
cmp -s "$work/bare" "$work/bare.expected" || fail 'an unquoted value is left as it was' "$(cat "$work/bare")"
grep -q 'add it yourself' "$work/warnings" || fail 'an unquoted value is warned about'
pass 'an unquoted value is warned about and left intact'

# A failed grub-mkconfig leaves the defaults as they were, so the next run
# starts over instead of finding console=tty0 already present and skipping
# the regeneration that never happened.
rm -f "$work/mkconfig" "$work/errors"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"\n' >"$work/retry"
cp "$work/retry" "$work/retry.expected"
if (
  source "$ROOT/bin/omarchy-system-btrfs-migrate"
  grub-mkconfig() { printf '%s\n' "$*" >>"$work/mkconfig"; return 1; }
  log() { :; }
  warn() { :; }
  fail() { printf '%s\n' "$*" >>"$work/errors"; exit 1; }
  OMARCHY_APPLE_COMPATIBLE=$work/apple OMARCHY_GRUB_DEFAULT=$work/retry ensure_display_console
); then
  fail 'a failed grub-mkconfig stops the staging'
fi
cmp -s "$work/retry" "$work/retry.expected" || fail 'a failed grub-mkconfig restores the defaults file' "$(cat "$work/retry")"
grep -q 'grub-mkconfig failed' "$work/errors" || fail 'a failed grub-mkconfig is reported' "$(cat "$work/errors" 2>/dev/null)"
pass 'a failed grub-mkconfig restores the defaults and stops the staging'

run_fixture "$work/apple" "$work/retry"
grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet console=tty0"' "$work/retry" ||
  fail 'the retry adds console=tty0 again' "$(cat "$work/retry")"
[[ $(mkconfig_calls) == 2 ]] || fail 'the retry regenerates grub.cfg' "$(mkconfig_calls) calls"
pass 'the retry after a failed grub-mkconfig finishes the job'

# The staging path must reach the function before the worker is staged, on
# both filesystem types, so the boot it stages can be answered.
for stage in stage_convert stage_encrypt; do
  body=$(sed -n "/^$stage() {/,/^}/p" "$ROOT/bin/omarchy-system-btrfs-migrate")
  grep -q 'ensure_display_console' <<<"$body" || fail "$stage calls ensure_display_console"
  console_line=$(grep -n 'ensure_display_console' <<<"$body" | cut -d: -f1)
  worker_line=$(grep -n 'stage_worker' <<<"$body" | cut -d: -f1)
  (( console_line < worker_line )) || fail "$stage fixes the console before staging the worker"
done
pass 'both staging paths fix the console before the worker is staged'
