#!/bin/bash
# Walks omarchy-mac-setup's step machine over every combination of machine
# state, including the one that bricked a MacBook: encrypting a root while
# /boot still lives on it. Needs no root — the script is sourced and next_step
# is called directly.

set -uo pipefail

TOOL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/omarchy-mac-setup"
pass=0
failures=0

# shellcheck source=/dev/null
source "$TOOL"
set +e # the script sets -e for its own run

# next_step <boot_separate> <encrypted> <want_encrypt> <installed>
step_is() {
  local expected="$1" actual
  shift
  actual=$(next_step "$@")
  if [[ $actual == "$expected" ]]; then
    echo "✓ [boot=$1 crypt=$2 want=$3 installed=$4] → $actual"
    ((++pass))
  else
    echo "✗ [boot=$1 crypt=$2 want=$3 installed=$4] → $actual (expected $expected)"
    ((++failures))
  fi
}

echo "=== encrypted install, from a fresh Asahi Alarm btrfs image ==="

# The order that matters: layout first, encryption second, Omarchy last.
step_is boot-layout 0 0 1 0
step_is encrypt 1 0 1 0
step_is omarchy 1 1 1 0
step_is done 1 1 1 1

echo
echo "=== unencrypted install ==="

# Without encryption the boot layout is nobody's business — an unencrypted
# root with /boot on it boots fine.
step_is omarchy 0 0 0 0
step_is omarchy 1 0 0 0
step_is done 0 0 0 1

echo
echo "=== states that must never produce an encryption step ==="

# Already encrypted: never stage it twice, whatever /boot looks like.
step_is omarchy 0 1 1 0
step_is done 1 1 1 1

# Installed wins over everything: a finished machine is finished.
step_is done 0 0 1 1
step_is done 0 1 0 1

echo
echo "=== the failure this ordering exists to prevent ==="

# /boot on the root filesystem must never reach the encrypt step, because GRUB
# would lose its modules and kernel behind the LUKS header.
for want in 0 1; do
  for installed in 0 1; do
    result=$(next_step 0 0 "$want" "$installed")
    if [[ $result == "encrypt" ]]; then
      echo "✗ encrypt reached with /boot on root (want=$want installed=$installed)"
      ((++failures))
    else
      echo "✓ no encrypt with /boot on root (want=$want installed=$installed) → $result"
      ((++pass))
    fi
  done
done

echo
echo "=== the branch must carry the tools this script drives ==="

# malik-na/quattro is a real Omarchy 4 branch that does not carry
# omarchy-system-boot-to-esp or omarchy-system-btrfs-migrate. Cloning it and
# only finding out at `bash $SRC/bin/...` would strand the machine with an
# enabled unit that fails on every boot.
repo=example/repo
ref=some-branch
forge=$DEFAULT_FORGE
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "✓ $label"
    ((++pass))
  else
    echo "✗ $label"
    ((++failures))
  fi
}

# require_tools_present exits rather than returns on refusal, so each case runs
# in a subshell.
refuses_checkout() {
  ! (require_tools_present "$1" >/dev/null 2>&1)
}

accepts_checkout() {
  (require_tools_present "$1" >/dev/null 2>&1)
}

mkdir -p "$work/bin"
check "an empty checkout is refused" \
  refuses_checkout "$work"

touch "$work/bin/omarchy-system-boot-to-esp"
check "half the tools is still refused" \
  refuses_checkout "$work"

touch "$work/bin/omarchy-system-btrfs-migrate"
check "a checkout with both tools passes" \
  accepts_checkout "$work"


# localectl is not present in a test environment, and the keymap path calls it.
# Stub it once, here, so every check below makes a decision rather than tripping
# over a missing command.
km_stub=$work/km
mkdir -p "$km_stub"
cat >"$km_stub/localectl" <<'STUB'
#!/bin/bash
case "$*" in
  *list-keymaps*) printf 'us\nuk\nde\ndvorak\n' ;;
  *) echo "     VC Keymap: de" ;;
esac
STUB
chmod +x "$km_stub/localectl"

echo
echo "=== the confirmation must not end the run ==="

# `[[ ... ]] && fail` as a function's last statement returns 1 on the path where
# the condition is false — the yes path — and set -e turns that into a silent
# exit at the call site. Answering "Y" used to quit the installer.
answers() {
  local input="$1"
  (
    set -e
    encrypt_flag=1 want_encrypt=1 username=scott hostname=pancake keymap=""
    repo=example/repo ref=some-branch
    PATH="$km_stub:$PATH"
    printf '%s' "$input" | ask_questions >/dev/null 2>&1
  )
}

not() {
  ! "$@"
}

refuses_to_start() {
  ! answers "$1"
}

check "answering Y starts the run" answers 'Y
'
check "answering y starts the run" answers 'y
'
check "pressing enter starts the run" answers '
'

# With no keymap set and a stub that would answer one, the run still starts:
# if a keymap question were asked, it would swallow the "Y" and the run would
# never reach the confirmation.
check "no keymap question swallows the answer" answers 'Y
'
check "answering n stops the run" refuses_to_start 'n
'
check "answering no stops the run" refuses_to_start 'no
'

echo
echo "=== hostnames ==="

check "a regular owner username is accepted" valid_username sfreiburg
check "root is refused as the owner" not valid_username root
check "a username beginning with a digit is refused" not valid_username 1owner

valid() {
  valid_hostname "$1"
}

invalid() {
  ! valid_hostname "$1"
}

check "a plain name is accepted" valid scotts-mac
check "digits are accepted" valid mac2
check "a fully qualified name is accepted" valid mac.home.arpa
check "the Asahi default is accepted" valid alarm
check "63 characters is accepted" valid "$(printf 'a%.0s' {1..63})"

check "empty is refused" invalid ""
check "a leading hyphen is refused" invalid -mac
check "a trailing hyphen is refused" invalid mac-
check "spaces are refused" invalid "my mac"
check "underscores are refused" invalid my_mac
check "a lone dot is refused" invalid .
check "an empty label is refused" invalid mac..home
check "64 characters in a label is refused" invalid "$(printf 'a%.0s' {1..64})"

# /etc/hosts wants the short name alongside a qualified one, and exactly once
# when the name has no domain.
hosts_entry_for() {
  local name="$1" short=${1%%.*}
  if [[ $name == "$short" ]]; then
    echo "$name"
  else
    echo "$name $short"
  fi
}

check "a qualified name carries its short form" \
  [ "$(hosts_entry_for mac.home.arpa)" = "mac.home.arpa mac" ]
check "a short name is not repeated" \
  [ "$(hosts_entry_for mac)" = "mac" ]


echo
echo "=== the initramfs check reads the config, not a built image ==="

# The first version of this check parsed lsinitcpio output and failed a
# perfectly good initramfs -- the rebuild had run [asahi] on screen while the
# check said it had not. Ask the config the build reads instead.
conf_dir=$work/mkinitcpio.conf.d
mkdir -p "$conf_dir"
printf 'HOOKS=(base udev autodetect block filesystems fsck)\n' >"$work/mkinitcpio.conf"

hooks_seen() {
  OMARCHY_MKINITCPIO_CONF="$work/mkinitcpio.conf" \
    OMARCHY_MKINITCPIO_CONFD="$conf_dir" effective_hooks
}

asahi_seen() {
  OMARCHY_MKINITCPIO_CONF="$work/mkinitcpio.conf" \
    OMARCHY_MKINITCPIO_CONFD="$conf_dir" hooks_include_asahi
}

check "the base config's hooks are read" \
  grep -q 'base udev autodetect' <<<"$(hooks_seen)"

check "no asahi when nothing provides it" not asahi_seen

# A drop-in that assigns HOOKS wholesale, the way omarchy_hooks.conf does.
printf 'HOOKS=(base udev plymouth block encrypt filesystems fsck)\n' \
  >"$conf_dir/50-omarchy.conf"
check "a drop-in assigning HOOKS wins over the base config" \
  grep -q 'plymouth' <<<"$(hooks_seen)"
check "and takes asahi with it when it does not list it" not asahi_seen

printf 'HOOKS=(base asahi udev block filesystems)\n' >"$conf_dir/60-asahi.conf"
check "a later drop-in putting asahi back is seen" asahi_seen

echo
echo "=== every step can be re-run by name ==="

# The state machine picks the order; --step is the manual override for a step
# that half-worked, or one that did not exist when the machine was installed.
is_known_step() {
  local candidate="$1" step
  for step in "${STEPS[@]}"; do
    [[ $step == "$candidate" ]] && return 0
  done
  return 1
}

# Every step next_step can produce has to be dispatchable by name, or the
# override cannot re-run the thing that just failed.
for produced in boot-layout encrypt omarchy done; do
  check "next_step's '$produced' can be run by name" is_known_step "$produced"
done

check "fonts is reachable by name" is_known_step fonts
check "autologin is reachable by name" is_known_step autologin
check "a typo is not a step" not is_known_step boot-later

echo
echo "=== keymaps ==="

# The console keymap is the keymap the LUKS prompt uses: omarchy_hooks.conf
# bundles vconsole.conf into the initramfs. A wrong one means the machine
# rejects a passphrase its owner is typing correctly.
known_keymap() {
  PATH="$km_stub:$PATH" valid_keymap "$1"
}

check "a known keymap is accepted" known_keymap us
check "case is ignored, as localectl does" known_keymap US
check "an unknown keymap is refused" not known_keymap nonsense
check "an empty keymap is refused" not known_keymap ""
check "the current keymap is read from localectl" \
  [ "$(PATH="$km_stub:$PATH" OMARCHY_VCONSOLE_CONF=$work/none current_keymap)" = "de" ]

# A machine whose localectl cannot list keymaps is not a machine with a bad
# keymap: refusing there would block an install over a missing lookup table.
empty_stub=$work/km-empty
mkdir -p "$empty_stub"
cat >"$empty_stub/localectl" <<'STUB'
#!/bin/bash
case "$*" in
  *list-keymaps*) : ;;
  *) echo "     VC Keymap: us" ;;
esac
STUB
chmod +x "$empty_stub/localectl"

unlistable_keymap() {
  PATH="$empty_stub:$PATH" valid_keymap "$1"
}

check "anything passes when keymaps cannot be listed" unlistable_keymap us
check "even an odd one, rather than blocking the install" unlistable_keymap whatever
check "empty is still refused" not unlistable_keymap ""

# systemd reports a machine that has never set a keymap as "(unset)" or "n/a".
# Both look like keymap names to anything that just takes the text after the
# colon, and both were then rejected as unknown -- stopping the install over a
# machine's own unset default.
unset_stub=$work/km-unset
mkdir -p "$unset_stub"
cat >"$unset_stub/localectl" <<'STUB'
#!/bin/bash
case "$*" in
  *list-keymaps*) printf 'us\nuk\nde\n' ;;
  *) echo "     VC Keymap: (unset)" ;;
esac
STUB
chmod +x "$unset_stub/localectl"

check "an unset keymap falls back to us" \
  [ "$(PATH="$unset_stub:$PATH" OMARCHY_VCONSOLE_CONF=$work/none current_keymap)" = "us" ]

printf 'KEYMAP=dvorak\n' >"$work/vconsole.conf"
check "vconsole.conf wins, since the initramfs reads that" \
  [ "$(PATH="$km_stub:$PATH" OMARCHY_VCONSOLE_CONF=$work/vconsole.conf current_keymap)" = "dvorak" ]
check "and that fallback validates" \
  bash -c 'PATH="'"$unset_stub"':$PATH"; '"$(declare -f valid_keymap keymaps_listable)"'; valid_keymap us'

echo
echo "=== a staged checkout has to be the one that was asked for ==="

# The version guard rejects a branch only after cloning it, so a refused run
# leaves a tree behind. Reusing it silently is how a corrected run got as far
# as "moving /boot onto the EFI partition" before finding no such file.
make_checkout() {
  local dir="$1" url="$2" branch="$3" with_tools="$4"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  git -C "$dir" checkout -q -b "$branch"
  if [[ $with_tools == "tools" ]]; then
    mkdir -p "$dir/bin"
    touch "$dir/bin/omarchy-system-boot-to-esp" "$dir/bin/omarchy-system-btrfs-migrate"
  fi
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm x --allow-empty
}

co=$work/checkout

make_checkout "$co" https://github.com/scottjones/omarchy-mac.git feat/btrfs-encrypt-only tools
check "the right repo, branch and tools is reused" \
  checkout_matches "$co" scottjones/omarchy-mac feat/btrfs-encrypt-only

check "a different branch is replaced" \
  not checkout_matches "$co" scottjones/omarchy-mac quattro
check "a different repo is replaced" \
  not checkout_matches "$co" malik-na/omarchy-mac feat/btrfs-encrypt-only

# The case that actually happened: a 3.x tree from the refused run.
make_checkout "$co" https://github.com/omarchy-mac/omarchy-mac.git main bare
check "the right branch without the tools is replaced" \
  not checkout_matches "$co" malik-na/omarchy-mac main

check "a directory that is not a checkout at all is replaced" \
  not checkout_matches "$work/nothing-here" malik-na/omarchy-mac main

echo
echo "=== autologin has to name a session that exists ==="

# Session=omarchy.desktop was copied from the ISO, where that file is
# installed. On a Mac the sessions are Hyprland's, so autologin pointed at a
# file that exists only in git -- SDDM logged in to nothing and the screen
# stayed black.
sessions=$work/sessions
mkdir -p "$sessions"

session_chosen() {
  OMARCHY_SESSIONS_DIR="$sessions" desktop_session
}

check "no sessions at all is refused rather than guessed" \
  bash -c 'OMARCHY_SESSIONS_DIR="'"$sessions"'"; '"$(declare -f desktop_session)"'; ! desktop_session'

touch "$sessions/hyprland.desktop"
check "plain hyprland is used when it is all there is" \
  [ "$(session_chosen)" = "hyprland.desktop" ]

touch "$sessions/hyprland-uwsm.desktop"
check "the uwsm session wins over plain hyprland" \
  [ "$(session_chosen)" = "hyprland-uwsm.desktop" ]

touch "$sessions/omarchy.desktop"
check "Omarchy's own session wins over both" \
  [ "$(session_chosen)" = "omarchy.desktop" ]

# SDDM scans /usr/share and /usr/local/share, and the omarchy package installs
# into the second. Checking only the first made a machine with a working
# Omarchy session look like it had none -- the log from a real one read
# "/usr/local/share/wayland-sessions/omarchy.desktop".
local_sessions=$work/local-sessions
mkdir -p "$local_sessions"
touch "$local_sessions/omarchy.desktop"

check "a session in the second directory is found" \
  bash -c 'OMARCHY_SESSIONS_DIR=""; '"$(declare -f session_dirs session_file_path desktop_session)"'
    session_dirs() { printf "%s\n" "'"$sessions"'" "'"$local_sessions"'"; }
    [[ $(desktop_session) == omarchy.desktop ]]'

echo
echo "=== an install is finished only if both signs agree ==="

# @factory is a top-level subvolume: rolling @ back to @fresh leaves it behind
# while removing the install it was evidence of. Asked on its own, it reported
# a rolled-back machine as finished, so --resume cleaned up and did nothing.
# install_complete <marker> <factory> <runtime> <display-manager>
#
# The marker is written by this script when step 3 finishes. The other three
# recognise a machine installed before the marker existed. @factory alone is not
# enough -- it is a top-level subvolume that survives a rollback -- and neither
# is the omarchy package, which lands early in the install. An install
# interrupted after the packages therefore satisfies both, which is exactly what
# reported "Setup complete" on a machine that had not finished. The display
# manager is enabled at the end, so it is what tells the two apart.
check "the marker alone is enough" install_complete 1 0 0 0
check "the marker wins even mid-install" install_complete 1 1 1 0

check "factory, package and display manager together: finished" \
  install_complete 0 1 1 1

check "an install interrupted after the packages is not finished" \
  not install_complete 0 1 1 0
check "a rolled-back machine with @factory still around is not finished" \
  not install_complete 0 1 0 0
check "packages without @factory is not finished" \
  not install_complete 0 0 1 1
check "nothing at all is a machine that has not started" \
  not install_complete 0 0 0 0

echo
echo "=== the setup unit must not fight the display manager for VT 1 ==="

# SDDM runs its greeter on VT 1; the unit takes tty1 to show its steps. On the
# last boot -- the one that runs the done step and retires the unit -- both
# wanted it at once and the session lost. That produced no desktop on the first
# boot after an install, twice in a row, working on every boot after because by
# then the unit was gone.
unit_text=$(sed -n '/^\[Unit\]/,/^\[Install\]/p' "$TOOL")

check "the unit is ordered before sddm" \
  grep -q '^Before=sddm.service' <<<"$unit_text"
check "it still takes tty1 away from the getty" \
  grep -q '^Conflicts=getty@tty1.service' <<<"$unit_text"
check "it still owns the console it prints to" \
  grep -q 'TTYPath=/dev/tty1' "$TOOL"
check "it dismisses the splash covering that console" \
  grep -q '^ExecStartPre=-/usr/bin/plymouth quit' "$TOOL"

echo
echo "=== piped in with curl, there is no file to install from ==="

# `curl ... | bash` gives the script no file on disk: it cannot install itself
# for the resume-on-boot unit, and every prompt would read from stdin, which is
# the script. It fetches a copy and hands over to that instead.
fetch_dir=$work/fetch
mkdir -p "$fetch_dir/bin"
SELF=$fetch_dir/omarchy-mac-setup
repo=example/repo
ref=some-branch
forge=$DEFAULT_FORGE

stub_curl() {
  local kind="$1" exitcode="${2:-0}"
  {
    echo '#!/bin/bash'
    echo 'for a in "$@"; do [[ $prev == -o ]] && out=$a; prev=$a; done'
    case $kind in
      script) echo 'printf "#!/bin/bash\\necho hi\\n" > "$out"' ;;
      html) echo 'printf "<html>404</html>\\n" > "$out"' ;;
      empty) echo ': > "$out"' ;;
    esac
    echo "exit $exitcode"
  } >"$fetch_dir/bin/curl"
  chmod +x "$fetch_dir/bin/curl"
}

fetch_ok() {
  rm -f "$SELF"
  (PATH="$fetch_dir/bin:$PATH"; fetch_self >/dev/null 2>&1) || return 1
  [[ -x $SELF ]]
}

stub_curl script
check "a fetched script is installed and executable" fetch_ok

stub_curl html
check "a 404 page is not mistaken for the script" not fetch_ok

stub_curl empty
check "an empty response is refused" not fetch_ok

stub_curl script 22
check "a failed download leaves nothing behind" not fetch_ok

check "running from a real file needs no fetch" \
  bash -c 'BASH_SOURCE0='"$TOOL"'; [[ -f '"$TOOL"' ]]'

echo
echo "=== the root password Asahi Alarm ships ==="

# Locking root closes a known password, but only once someone else can get in:
# locking it on a machine whose owner has no password would leave nothing that
# can log in at all.
check "locked once the owner has a password" should_lock_root 0 1
check "not locked when the owner has none" not should_lock_root 0 0
check "not locked when asked to keep it" not should_lock_root 1 1
check "keeping it wins even with a password set" not should_lock_root 1 0

# passwd -S says P for a usable password, L for locked, NP for none.
pw_stub=$work/pw
mkdir -p "$pw_stub"
cat >"$pw_stub/passwd" <<'STUB'
#!/bin/bash
case "$2" in
  haspw) echo "haspw P 2026-08-19 0 99999 7 -1" ;;
  locked) echo "locked L 2026-08-19 0 99999 7 -1" ;;
  nopw) echo "nopw NP 2026-08-19 0 99999 7 -1" ;;
esac
STUB
chmod +x "$pw_stub/passwd"

has_password() {
  PATH="$pw_stub:$PATH" user_has_password "$1"
}

check "a usable password is recognised" has_password haspw
check "a locked account is not a usable password" not has_password locked
check "no password is not a usable password" not has_password nopw
check "an unknown user is not a usable password" not has_password ghost

echo
echo "=== arriving through a pipe, with no file behind the script ==="

# These run the real script through `bash -s`, the way `curl ... | bash` does.
# Sourcing it or stubbing BASH_SOURCE cannot catch this: under a pipe
# BASH_SOURCE is an empty array, and set -u then kills the run at the
# bottom-of-file guard before main() is ever reached. That shipped once --
# "unbound variable BASH_SOURCE[0]" on a fresh Asahi install -- so the check
# has to actually pipe. Each assertion is a function, because `check` runs its
# argument directly and a `bash -c` subshell would not inherit $TOOL.
piped() {
  cat "$TOOL" | bash -s -- "$@" 2>&1
}

# Every assertion captures the output before grepping it. Piping straight into
# `grep -q` looks equivalent but is not: grep exits on the first match, the
# still-writing bash takes SIGPIPE, and pipefail -- left on by sourcing the
# tool above -- fails the pipeline even though the match succeeded. Negated
# checks then "pass" on the 141 rather than on what they claim to test.
matches() {
  local pattern="$1" text="$2"
  grep -qiE -- "$pattern" <<<"$text"
}

echo
echo "=== retiring the Asahi bootstrap administrator ==="

retirement_run() {
  local owner="$1" alarm_exists="$2" alarm_in_wheel="$3" removal_ok=${4:-1}
  (
    id() {
      [[ $1 == "-u" && $2 == "alarm" && $alarm_exists == 1 ]]
    }
    user_in_group() {
      [[ $1 == "alarm" && $2 == "wheel" && $alarm_in_wheel == 1 ]]
    }
    gpasswd() {
      printf 'GPASSWD: %s\n' "$*" >&2
      [[ $removal_ok == 1 ]]
    }
    log() { :; }
    retire_asahi_admin "$owner"
  )
}

check "alarm is removed when a different owner takes over" \
  matches 'GPASSWD: -d alarm wheel' "$(retirement_run sfreiburg 1 1 2>&1)"

check "alarm remains an administrator when it is the chosen owner" \
  not matches 'GPASSWD:' "$(retirement_run alarm 1 1 2>&1)"

check "a missing alarm account needs no cleanup" \
  not matches 'GPASSWD:' "$(retirement_run sfreiburg 0 0 2>&1)"

check "an already-demoted alarm account needs no cleanup" \
  not matches 'GPASSWD:' "$(retirement_run sfreiburg 1 0 2>&1)"

failed_retirement_is_refused() {
  ! retirement_run sfreiburg 1 1 0 >/dev/null 2>&1
}

check "a failed alarm demotion stops the handoff" failed_retirement_is_refused

ensure_user_run() {
  local existing="$1" has_password="$2"
  (
    username=owner
    ensure_wheel_sudo() { :; }
    id() { [[ $existing == 1 ]]; }
    useradd() { echo USERADD; }
    user_has_password() { [[ $has_password == 1 ]]; }
    passwd() { echo PASSWD; return 0; }
    usermod() { echo USERMOD; }
    user_in_group() { return 0; }
    retire_asahi_admin() { echo RETIRE_ALARM; }
    lock_root_account() { echo LOCK_ROOT; }
    log() { :; }
    ensure_user
  )
}

new_owner_run=$(ensure_user_run 0 0)
existing_owner_run=$(ensure_user_run 1 1)
passwordless_owner_run=$(ensure_user_run 1 0)

check "a new owner is created and given a password before the handoff" \
  [ "$new_owner_run" = $'USERADD\nPASSWD\nUSERMOD\nRETIRE_ALARM\nLOCK_ROOT' ]

check "an existing owner keeps its password and is made an administrator" \
  [ "$existing_owner_run" = $'USERMOD\nRETIRE_ALARM\nLOCK_ROOT' ]

check "a passwordless existing owner gets a password before the handoff" \
  [ "$passwordless_owner_run" = $'PASSWD\nUSERMOD\nRETIRE_ALARM\nLOCK_ROOT' ]

root_owner_run=$(
  (
    username=root
    ensure_wheel_sudo() { echo MUTATED; }
    ensure_user
  ) 2>&1
)
root_owner_status=$?

check "root is rejected at the account-mutation boundary" [ "$root_owner_status" != "0" ]
check "rejecting root happens before account mutation" not matches MUTATED "$root_owner_run"

no_unbound_when_piped() { ! matches 'unbound variable' "$(piped --status)"; }
piped_reaches_main() { matches 'Omarchy Mac setup status' "$(piped --status)"; }
piped_help_is_useful() { matches '[-][-]status' "$(piped --help)"; }
piped_help_is_clean() { ! matches 'no such file|unbound variable' "$(piped --help)"; }
file_help_prints_header() { matches 'carries the' "$(bash "$TOOL" --help 2>&1)"; }
sourcing_runs_nothing() { ! matches 'Omarchy Mac setup' "$(bash -c 'source "$1"' _ "$TOOL" 2>&1)"; }

check "piped --status does not die on an unbound variable" no_unbound_when_piped
check "piped --status reaches main and prints the status" piped_reaches_main
check "piped --help says something useful instead of failing" piped_help_is_useful
check "piped --help does not error on a missing source file" piped_help_is_clean
check "run from a file, --help still prints the header" file_help_prints_header
check "sourcing still does not run main" sourcing_runs_nothing

echo "=== the piped re-exec carries its arguments ==="

# The parse loop shifts every argument away, so "$@" is empty by the time the
# re-exec runs. That shipped: a piped run with --repo/--ref fetched the right
# script, then re-ran it with no arguments at all and went for the DEFAULT repo
# and branch -- Omarchy 3 upstream instead of the branch asked for. Only the
# unrelated Omarchy-3 guard caught it.
#
# Stubs walk main() to that one line without root: running_from_a_file reports
# a pipe, fetch_self does nothing, fail is made non-fatal so the EUID check
# does not end the run, and exec is shadowed by a function so this process
# survives to be asserted on.
#
# It has to run under a pty. The re-exec carries a `</dev/tty` redirection, and
# with no controlling terminal that redirection fails -- which skips the call
# entirely and falls through into the interactive prompts, hanging the suite
# instead of failing it. `script` supplies the terminal; timeout is the
# backstop if a future change reintroduces the fall-through.
reexec_command() {
  local harness output
  harness=$(mktemp)
  cat >"$harness" <<'HARNESS'
source "$TOOL" 2>/dev/null
set +e
running_from_a_file() { return 1; }
fetch_self() { :; }
load_conf() { :; }
fail() { :; }
exec() { printf 'EXEC: %s\n' "$*"; exit 0; }
main --from-source --repo scottjones/omarchy-mac --ref feat/btrfs-encrypt-only
HARNESS
  output=$(TOOL="$TOOL" timeout 30 script -qec "bash '$harness'" /dev/null 2>/dev/null | tr -d '\r')
  rm -f "$harness"
  printf '%s\n' "$output"
}

reexec_output=$(reexec_command)

check "the re-exec happens at all" \
  matches 'EXEC:' "$reexec_output"

check "--repo survives the parse loop" \
  matches 'repo scottjones/omarchy-mac' "$reexec_output"

check "--ref survives the parse loop" \
  matches 'ref feat/btrfs-encrypt-only' "$reexec_output"

check "it re-runs the copy installed on disk" \
  matches 'omarchy-mac-setup' "$reexec_output"

echo "=== the forge the repo is fetched from ==="

# One forge being unreachable should not stop an install: codeberg.org stopped
# completing TCP handshakes partway through one. The raw-file URL differs by
# forge -- GitHub serves raw files from another host entirely -- so both shapes
# are pinned here, and no call site may hardcode a host.
raw_for() { ( repo=owner/repo; ref=some-branch; forge=$1; raw_url bin/omarchy-mac-setup ); }
clone_for() { ( repo=owner/repo; forge=$1; clone_url ); }

check "a Forgejo forge uses its raw/branch path" \
  [ "$(raw_for codeberg.org)" = "https://codeberg.org/owner/repo/raw/branch/some-branch/bin/omarchy-mac-setup" ]

check "github serves raw files from raw.githubusercontent.com" \
  [ "$(raw_for github.com)" = "https://raw.githubusercontent.com/owner/repo/some-branch/bin/omarchy-mac-setup" ]

check "the clone URL follows the chosen forge" \
  [ "$(clone_for github.com)" = "https://github.com/owner/repo.git" ]

check "a self-hosted Forgejo works too" \
  [ "$(clone_for git.example.org)" = "https://git.example.org/owner/repo.git" ]

# A hardcoded host would silently ignore --forge at that one call site, which is
# the failure this change exists to prevent.
check "no call site hardcodes a forge host" \
  [ "$(grep -c 'https://codeberg\.org' "$TOOL")" = "0" ]

forge_persists() {
  grep -qF "printf 'SETUP_FORGE=%q\\n' \"\$forge\"" "$TOOL" &&
    grep -qF 'forge=${SETUP_FORGE:-$forge}' "$TOOL"
}

check "the forge survives a reboot in the conf file" forge_persists

echo "=== saved answers are inert shell data ==="

# The resume path sources /etc/omarchy-mac-setup.conf as root. An unescaped
# --ref such as $(touch marker) used to become command substitution in that
# file, so a value supplied to the first invocation ran on the next boot.
conf_file=$work/setup.conf
conf_marker=$work/conf-injected
conf_is_safe() {
  (
    CONF=$conf_file
    want_encrypt=1
    username=owner
    hostname=box
    keymap=us
    repo=owner/repo
    ref="\$(touch \"$conf_marker\")"
    forge=git.example.org

    save_conf
    [[ ! -e $conf_marker ]] || return 1

    unset WANT_ENCRYPT SETUP_USER SETUP_HOSTNAME SETUP_KEYMAP SETUP_REPO SETUP_REF SETUP_FORGE
    # shellcheck source=/dev/null
    . "$CONF"
    [[ ! -e $conf_marker && $SETUP_REF == "$ref" ]]
  )
}

check "resume answers cannot execute shell syntax" conf_is_safe

echo "=== questions and status read the machine, not the intent flag ==="

# Re-running against a machine that is already encrypted -- a resumed install,
# or a rollback to a snapshot taken after step 2 -- used to ask "Encrypt the
# disk?", then promise to "encrypt the root" in the plan, then report encryption
# as "requested". All three describe intent, while next_step reads the disk, so
# they contradicted what was about to happen and invited a "no" that could not
# be honoured.
#
# read -rp only draws its prompt when stdin is a terminal, so these assert on
# the plan and status text rather than on the prompt itself.
ask_with() {
  local state="$1" input="$2"
  (
    username=someone hostname=box keymap=us encrypt_flag="" want_encrypt=0
    repo=owner/repo ref=branch
    banner() { :; }
    warn() { :; }
    log() { printf '%s\n' "$*"; }
    valid_hostname() { return 0; }
    valid_keymap() { return 0; }
    current_hostname() { echo box; }
    current_keymap() { echo us; }
    fail() { printf 'STOPPED: %s\n' "$*"; exit 1; }
    if [[ $state == "encrypted" ]]; then
      root_is_encrypted() { return 0; }
      boot_is_separate() { return 0; }
    else
      root_is_encrypted() { return 1; }
      boot_is_separate() { return 1; }
    fi
    printf '%s' "$input" | ask_questions 2>/dev/null
    echo "WANT_ENCRYPT=$want_encrypt"
  )
}

encrypted_run=$(ask_with encrypted '\n')
plain_run=$(ask_with plain 'y\n\n')

check "an encrypted root is reported, not asked about" \
  matches 'already encrypted' "$encrypted_run"

no_encrypt_promise() { ! matches 'encrypt the root' "$encrypted_run"; }
check "the plan does not offer to encrypt an encrypted root" no_encrypt_promise

no_boot_promise() { ! matches 'move /boot' "$encrypted_run"; }
check "the plan does not offer to move an already-separate /boot" no_boot_promise

check "an unencrypted root is still asked about and planned" \
  matches 'encrypt the root' "$plain_run"

check "a /boot on the root filesystem is still planned for" \
  matches 'move /boot' "$plain_run"

echo
echo "=== the status line reports the disk ==="

status_with() {
  local encrypted="$1" want="$2"
  (
    want_encrypt=$want
    banner() { :; }
    current_step() { echo omarchy; }
    current_hostname() { echo box; }
    root_source() { echo /dev/mapper/root; }
    boot_is_separate() { return 0; }
    omarchy_is_installed() { return 1; }
    findmnt() { echo /dev/sda1; }
    if (( encrypted )); then
      root_is_encrypted() { return 0; }
    else
      root_is_encrypted() { return 1; }
    fi
    print_status
  )
}

check "an encrypted root reports encryption done" \
  matches 'encryption +done' "$(status_with 1 1)"

check "an unencrypted root with the flag set still reports requested" \
  matches 'encryption +requested' "$(status_with 0 1)"

check "an unencrypted root without the flag reports not requested" \
  matches 'encryption +not requested' "$(status_with 0 0)"

echo "=== a finished machine is not worked on before being told it is finished ==="

# Reaching the done step only after the setup block meant an already-complete
# machine had its root account locked, its user re-created, its GRUB font
# rebuilt and its keymap reapplied -- and was then told there was nothing to do.
# Stubs report what would have run; fail is neutered so the EUID and
# architecture checks do not end the run on a development machine.
finished_machine_run() {
  (
    resume=0 step_only="" abort=0 status=0
    username=someone hostname=box keymap=us want_encrypt=1
    repo=owner/repo ref=branch forge=codeberg.org
    invocation=()
    fail() { :; }
    quiet_console() { :; }
    on_exit() { :; }
    load_conf() { :; }
    current_step() { echo done; }
    ask_questions() { echo "ASKED QUESTIONS"; }
    require_network() { :; }
    ensure_source_checkout() { echo "CLONED"; }
    ensure_user() { echo "CREATED USER"; }
    lock_root_account() { echo "LOCKED ROOT"; }
    setup_console_font() { echo "CONSOLE FONT"; }
    setup_grub_font() { echo "GRUB FONT"; }
    apply_keymap() { echo "APPLIED KEYMAP"; }
    apply_hostname() { echo "APPLIED HOSTNAME"; }
    save_conf() { :; }
    install_self() { :; }
    run_step() { echo "RAN STEP: $1"; }
    main --from-source
  ) 2>&1
}

finished_run=$(finished_machine_run)

check "it runs the done step" matches 'RAN STEP: done' "$finished_run"

no_questions_asked() { ! matches 'ASKED QUESTIONS' "$finished_run"; }
no_user_created() { ! matches 'CREATED USER' "$finished_run"; }
no_fonts_rebuilt() { ! matches 'GRUB FONT|CONSOLE FONT' "$finished_run"; }
no_clone_made() { ! matches 'CLONED' "$finished_run"; }

check "it asks nothing" no_questions_asked
# ensure_user is also what locks the root account, so this covers both.
check "it does not re-create the user or relock root" no_user_created
check "it does not rebuild the fonts" no_fonts_rebuilt
check "it does not clone the repo" no_clone_made

echo "=== an existing checkout is brought to the requested ref ==="

# @home is not part of a root rollback, so a previous run's clone of
# ~/.local/share/omarchy survives a restore of @fresh. Treating any .git as
# good enough meant "install <repo> (<ref>)" installed whatever commit was left
# there -- which is how a re-run kept building a package the branch had already
# dropped, five commits behind and silent about it.
checkout_is_fetched() { grep -qF 'fetch --prune origin "$ref"' "$TOOL"; }
checkout_is_reset() { grep -qF 'checkout -B "$ref" FETCH_HEAD' "$TOOL"; }
checkout_remote_is_set() { grep -qF 'remote set-url origin "$(clone_url)"' "$TOOL"; }

check "an existing checkout is fetched" checkout_is_fetched
check "and moved onto the requested ref" checkout_is_reset
check "and pointed at the requested forge and repo" checkout_remote_is_set

echo "=== $pass checks passed, $failures failed ==="
(( failures == 0 ))
