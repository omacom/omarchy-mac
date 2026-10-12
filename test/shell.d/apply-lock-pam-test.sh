#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-apply-lock writes the lock screen's PAM stack. pam_faillock's
# preauth check must not be silent: a locked account refuses the right
# password, and its notice is the only thing that tells the user why (#705).

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
fake_root="$tmp/root"
mkdir -p "$stub" "$fake_root/etc/pam.d"

cat >"$stub/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
cat >"$stub/tee" <<'SH'
#!/bin/bash
cat >"$FAKE_ROOT$1"
SH
cat >"$stub/rm" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$stub/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 1
SH
cat >"$stub/omarchy-shell" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$stub"/*

FAKE_ROOT="$fake_root" PATH="$stub:$PATH" bash "$ROOT/bin/omarchy-apply-lock" >/dev/null

stack="$fake_root/etc/pam.d/omarchy-lock-password"
[[ -f $stack ]] || fail "omarchy-apply-lock writes /etc/pam.d/omarchy-lock-password"

if grep -qE '^auth +required +pam_faillock\.so preauth deny=10 unlock_time=120$' "$stack"; then
  pass "pam_faillock preauth runs without silent so a lockout is reported"
else
  fail "pam_faillock preauth runs without silent so a lockout is reported" "$(cat "$stack")"
fi

if grep -qE 'pam_faillock\.so authfail deny=10 unlock_time=120' "$stack" && grep -qE 'pam_faillock\.so authsucc' "$stack"; then
  pass "the tally is still kept (authfail and authsucc)"
else
  fail "the tally is still kept (authfail and authsucc)" "$(cat "$stack")"
fi

if ! grep -q 'silent' "$stack"; then
  pass "nothing in the lock stack is silent"
else
  fail "nothing in the lock stack is silent" "$(cat "$stack")"
fi
