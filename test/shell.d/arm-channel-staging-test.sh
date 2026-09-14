#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/install/helpers/arm-channel.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export TEST_STAGE_ROOT="$test_tmp/system" TEST_STAGE_CALLS="$test_tmp/calls"
mkdir -p "$test_tmp/bin" "$test_tmp/home" "$TEST_STAGE_ROOT/var/cache"
chmod 700 "$test_tmp/home"
chmod 755 "$TEST_STAGE_ROOT" "$TEST_STAGE_ROOT/var" "$TEST_STAGE_ROOT/var/cache"
# Run the exact privileged program against disposable directories. Only its
# fixed /var prefix and root ownership probe are modeled; real modes, symlinks,
# mktemp, mkdir, chmod and rmdir exercise the allocation/failure contract.
sudo() {
  local -a args=("$@")
  [[ ${args[0]} == bash && ${args[3]} == -c ]] || return 99
  args[4]=${args[4]//\/var/$TEST_STAGE_ROOT/var}
  "${args[@]}"
}
cat >"$test_tmp/bin/stat" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
if [[ $* == '-c %u %a -- '* && ( ${@: -1} == "$TEST_STAGE_ROOT"/* || ${@: -1} == / ) ]]; then
  printf '%s %s\n' "$([[ ${@: -1} == / ]] && echo 0 || echo "${TEST_STAGE_OWNER:-0}")" "$(/usr/bin/stat -c %a -- "${@: -1}")"
else
  /usr/bin/stat "$@"
fi
SCRIPT
cat >"$test_tmp/bin/findmnt" <<'SCRIPT'
#!/bin/bash
if [[ -n ${TEST_STAGE_FSTYPE:-} ]]; then
  printf '%s\n' "$TEST_STAGE_FSTYPE"
else
  /usr/bin/findmnt "$@"
fi
SCRIPT
cat >"$test_tmp/bin/chown" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_STAGE_CALLS"
exit "${TEST_STAGE_CHOWN_STATUS:-0}"
SCRIPT
chmod +x "$test_tmp/bin/"*
export PATH="$test_tmp/bin:$PATH" HOME="$test_tmp/home" XDG_CACHE_HOME="$test_tmp/home/private-cache"
first=$(omarchy_arm_channel_stage_new)
second=$(omarchy_arm_channel_stage_new)
[[ $first != "$second" && $first == "$TEST_STAGE_ROOT/var/cache/omarchy/channels/transaction."* ]] || fail 'separate unique system-cache stages'
[[ $(stat -c %a "$first") == 755 && $(stat -c %a "$HOME") == 700 && ! -e $XDG_CACHE_HOME ]] || fail 'download traversal never changes private home/cache'
[[ $(cat "$TEST_STAGE_CALLS") == "$(id -u):$(id -g) $first"$'\n'"$(id -u):$(id -g) $second" ]] || fail 'chown is restricted to the new transaction children'
pass 'fresh and repeated channel staging use unique traversable disk cache children without changing HOME'
rmdir "$first" "$second"

for condition in symlink writable private wrong-owner ram; do
  path="$TEST_STAGE_ROOT/var/cache/omarchy/channels"
  case "$condition" in
    symlink) rmdir "$path"; mkdir "$test_tmp/administrator"; ln -s "$test_tmp/administrator" "$path" ;;
    writable) chmod 777 "$path" ;;
    private) chmod 700 "$path" ;;
    wrong-owner) export TEST_STAGE_OWNER=1234 ;;
    ram) export TEST_STAGE_FSTYPE=tmpfs ;;
  esac
  : >"$TEST_STAGE_CALLS"
  if omarchy_arm_channel_stage_new >"$test_tmp/rejected" 2>&1; then fail "$condition cache parent must refuse"; fi
  [[ ! -s $TEST_STAGE_CALLS ]] || fail "$condition must not chown any existing tree"
  case "$condition" in
    symlink) [[ -L $path && -z $(ls -A "$test_tmp/administrator") ]] || fail 'preserve administrator symlink'; rm "$path"; mkdir -m755 "$path" ;;
    writable) [[ $(stat -c %a "$path") == 777 ]] || fail 'preserve writable parent mode'; chmod 755 "$path" ;;
    private) [[ $(stat -c %a "$path") == 700 ]] || fail 'preserve private parent mode'; chmod 755 "$path" ;;
    wrong-owner) unset TEST_STAGE_OWNER ;;
    ram) unset TEST_STAGE_FSTYPE ;;
  esac
done
pass 'unsafe, private, symlink and RAM-backed parent paths are preserved and rejected'

if TEST_STAGE_CHOWN_STATUS=1 omarchy_arm_channel_stage_new >"$test_tmp/rejected" 2>&1; then fail 'failed allocation ownership must fail'; fi
[[ -z $(ls -A "$TEST_STAGE_ROOT/var/cache/omarchy/channels") ]] || fail 'failed empty allocation must be removed'
[[ $(stat -c %a "$HOME") == 700 ]] || fail 'HOME remains private after failures'
pass 'allocation failure removes only its new empty transaction'
