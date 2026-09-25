#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT

cat >"$tmp/blkid" <<'EOF'
#!/bin/bash
echo /dev/test-luks
EOF

cat >"$tmp/gum" <<'EOF'
#!/bin/bash
head -n 1 "$TEST_INPUTS"
sed -i '1d' "$TEST_INPUTS"
EOF

cat >"$tmp/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >>"$TEST_ARGS"
if [[ $* == *chpasswd* ]]; then
  cat >>"$TEST_CHPASSWD"
  exit 0
fi
cat >"$TEST_STDIN"
exit ${TEST_CRYPTSETUP_STATUS:-0}
EOF

cat >"$tmp/omarchy-hw-apple-silicon" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$tmp/chpasswd" <<'EOF'
#!/bin/bash
cat >>"$TEST_CHPASSWD_DIRECT"
EOF

cat >"$tmp/logname" <<'EOF'
#!/bin/bash
echo testuser
EOF

chmod +x "$tmp"/{blkid,gum,sudo,omarchy-hw-apple-silicon,chpasswd,logname}
export PATH="$tmp:$ROOT/bin:$PATH"
export TEST_ARGS="$tmp/args" TEST_INPUTS="$tmp/inputs" TEST_STDIN="$tmp/stdin" TEST_CHPASSWD="$tmp/chpasswd.out"
export TEST_CHPASSWD_DIRECT="$tmp/chpasswd-direct.out"
export SUDO_USER=testuser
: >"$TEST_ARGS"
: >"$TEST_CHPASSWD"
: >"$TEST_CHPASSWD_DIRECT"

printf 'new password\nnew password\n' >"$TEST_INPUTS"
"$ROOT/bin/omarchy-drive-password" >/dev/null

[[ $(<"$TEST_STDIN") == "new password" ]] || fail "Apple drive password passes the validated passphrase without a newline"
grep -F 'cryptsetup luksChangeKey' "$TEST_ARGS" >/dev/null || fail "Apple drive password changes the LUKS key"
grep -Fx /dev/test-luks "$TEST_ARGS" >/dev/null || fail "Apple drive password targets the selected drive"
[[ ! -s $TEST_CHPASSWD && ! -s $TEST_CHPASSWD_DIRECT ]] || fail "disk password must not change account passwords"
! grep -F 'limine-update' "$TEST_ARGS" >/dev/null || fail "disk password does not rebuild a Limine UKI"
pass "Apple disk password uses the shared LUKS-only behavior"

: >"$TEST_ARGS"
: >"$TEST_STDIN"
export TEST_CRYPTSETUP_STATUS=1
printf 'new password\nnew password\n' >"$TEST_INPUTS"
if "$ROOT/bin/omarchy-drive-password" >/dev/null; then
  fail "drive password stops when cryptsetup fails"
fi
[[ ! -s $TEST_CHPASSWD && ! -s $TEST_CHPASSWD_DIRECT ]] || fail "failed disk password change must not change account passwords"
pass "failed disk password change leaves account passwords alone"

unset SUDO_USER TEST_CRYPTSETUP_STATUS
cat >"$tmp/logname" <<'EOF'
#!/bin/bash
exit 1
EOF
printf 'new password\nnew password\n' >"$TEST_INPUTS"
"$ROOT/bin/omarchy-drive-password" >/dev/null
[[ ! -s $TEST_CHPASSWD && ! -s $TEST_CHPASSWD_DIRECT ]] || fail "disk password change must not require a login account"
pass "disk password change works without login-account discovery"
