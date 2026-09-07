#!/bin/bash

# The 1Password browser extension unlocks from the desktop app through
# 1Password-BrowserSupport, and only when that binary is setgid to the
# onepassword group. The aarch64 installer unpacks the official tarball, which
# carries none of the .install hooks the x86 package gets, so this setup has to
# be done by hand or the extension and the app stay separate logins.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
install_dir="$test_tmp/opt/1Password"
mkdir -p "$mock_bin" "$install_dir"

# An install that predates the browser-support setup: the app is on disk, the
# helper binary is present, and neither the group nor the setgid bit exists.
touch "$install_dir/1Password-BrowserSupport"
bin_link="$test_tmp/bin-link/1password"
mkdir -p "$(dirname "$bin_link")"
printf '#!/bin/bash\necho 8.12.0\n' >"$bin_link"
chmod +x "$bin_link"

cat >"$mock_bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH

cat >"$mock_bin/getent" <<'SH'
#!/bin/bash
[[ ${OMARCHY_TEST_GROUP_EXISTS:-false} == "true" ]]
SH

for cmd in groupadd chgrp chmod; do
  cat >"$mock_bin/$cmd" <<SH
#!/bin/bash
printf '$cmd:%s\n' "\$*" >>"\$OMARCHY_TEST_LOG"
SH
done

# The installer refuses to run anywhere but aarch64, so the architecture has to
# be stubbed here or this test only passes when it happens to run on an Apple
# Silicon machine and silently skips the whole installer everywhere else.
cat >"$mock_bin/uname" <<'SH'
#!/bin/bash
[[ ${1:-} == "-m" ]] && { echo aarch64; exit 0; }
exec /usr/bin/uname "$@"
SH

chmod +x "$mock_bin"/*

run_installer() {
  PATH="$mock_bin:$PATH" \
    OMARCHY_TEST_GROUP_EXISTS="$1" \
    OMARCHY_TEST_LOG="$2" \
    OMARCHY_1PASSWORD_INSTALL_DIR="$install_dir" \
    OMARCHY_1PASSWORD_BIN_LINK="$bin_link" \
    bash "$ROOT/bin/omarchy-install-1password" >/dev/null
}

# Already installed: the installer must still repair the browser integration
# rather than exiting early, which is what the package's post_upgrade does.
log="$test_tmp/log-missing"
: >"$log"
run_installer false "$log"

grep -Fxq 'groupadd:onepassword' "$log" ||
  fail "installer creates the onepassword group" "$(cat "$log")"
pass "installer creates the onepassword group"

grep -Fxq "chgrp:onepassword $install_dir/1Password-BrowserSupport" "$log" ||
  fail "installer gives 1Password-BrowserSupport the onepassword group" "$(cat "$log")"
pass "installer gives 1Password-BrowserSupport the onepassword group"

grep -Fxq "chmod:g+s $install_dir/1Password-BrowserSupport" "$log" ||
  fail "installer sets the setgid bit on 1Password-BrowserSupport" "$(cat "$log")"
pass "installer sets the setgid bit on 1Password-BrowserSupport"

# An existing group is left alone: groupadd would fail the script under set -e.
log="$test_tmp/log-present"
: >"$log"
run_installer true "$log"

grep -q '^groupadd:' "$log" &&
  fail "installer does not re-create an existing onepassword group" "$(cat "$log")"
pass "installer does not re-create an existing onepassword group"

grep -Fxq "chmod:g+s $install_dir/1Password-BrowserSupport" "$log" ||
  fail "installer still repairs setgid when the group already exists" "$(cat "$log")"
pass "installer still repairs setgid when the group already exists"
