#!/bin/bash

source "$(dirname "$0")/base-test.sh"

# First run offers Wi-Fi when the session has no route out, then holds the
# update prompt until one appears. NetworkManager's overall state drives both:
# nm-online answers for it, and nmcli reports it one reading per call, the last
# reading standing once the scripted sequence runs out.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/nm-online" <<'SH'
#!/bin/bash
[[ " $* " == *" -s "* ]] && exit 0
state=$(head -n 1 "$NM_TEST_STATES")
[[ $state == connected* ]]
SH
cat >"$mock_bin/nmcli" <<'SH'
#!/bin/bash
[[ $* == "-t -f STATE general" ]] || exit 2
echo x >>"$NM_TEST_POLLS"
line=$(wc -l <"$NM_TEST_POLLS")
total=$(wc -l <"$NM_TEST_STATES")
((line <= total)) || line=$total
sed -n "${line}p" "$NM_TEST_STATES"
SH
cat >"$mock_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
while (($#)); do
  case "$1" in
    -u | -g) shift 2 ;;
    *) echo "$1" >>"$NM_TEST_TOASTS"; exit 0 ;;
  esac
done
SH
printf '#!/bin/bash\nexit 0\n' >"$mock_bin/sleep"
chmod +x "$mock_bin"/*

run_wifi() {
  local name="$1"
  shift

  case_dir="$test_tmp/$name"
  mkdir -p "$case_dir"
  printf '%s\n' "$@" >"$case_dir/states"
  : >"$case_dir/polls"
  : >"$case_dir/toasts"

  PATH="$mock_bin:$PATH" NM_TEST_STATES="$case_dir/states" NM_TEST_POLLS="$case_dir/polls" \
    NM_TEST_TOASTS="$case_dir/toasts" \
    timeout 20 bash -c 'source "$1"; wait' _ "$ROOT/install/user/first-run/wifi.sh" ||
    fail "$name: first-run Wi-Fi step finishes"
}

toasts() {
  paste -sd, "$case_dir/toasts"
}

run_wifi no-network "disconnected" "disconnected" "connected"
[[ $(toasts) == "Setup Wi-Fi,Update System" ]] ||
  fail "no network offers Wi-Fi, then the update once online" "toasts: $(toasts)"
pass "no network offers Wi-Fi, then the update once online"

run_wifi online "connected"
[[ $(toasts) == "Update System" ]] || fail "a connected machine is not offered Wi-Fi" "toasts: $(toasts)"
pass "a connected machine is not offered Wi-Fi"

# A default route with a failing connectivity probe stays as before: the
# network panel shows it as limited, and Wi-Fi is not pushed over it.
run_wifi site-only "connected (site only)"
[[ $(toasts) == "Update System" ]] || fail "a routed but limited link is not offered Wi-Fi" "toasts: $(toasts)"
pass "a routed but limited link is not offered Wi-Fi"

# A Mac cabled to another computer by Thunderbolt: NetworkManager activates the
# link with only a link-local address, so nm-online calls it connected.
run_wifi link-local "connected (local only)" "connected (local only)" "connected (local only)" "connected"
[[ $(toasts) == "Setup Wi-Fi,Update System" ]] ||
  fail "a link-local-only link offers Wi-Fi and holds the update" "toasts: $(toasts)"
(($(wc -l <"$case_dir/polls") >= 4)) || fail "the update waits for a route out"
pass "a link-local-only link offers Wi-Fi and holds the update"
