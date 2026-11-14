#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

manual=https://omarchy.org/manual/mac-support/
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
calls="$test_tmp/calls"
mkdir -p "$mock_bin"

# Everything these scripts would reach for to change a machine. Each stub only
# records that it ran.
for command in sudo su pacman pacman-key yay makepkg git curl wget useradd \
  usermod passwd chpasswd groupadd systemctl gpg install cp mv rm ln mkdir \
  chown chmod tee; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"%s"\n' "$command" "$calls" >"$mock_bin/$command"
  chmod +x "$mock_bin/$command"
done

for script in bootstrap.sh setup.sh install.sh bin/omarchy-upgrade-to-quattro-mac; do
  : >"$calls"
  work="$test_tmp/work-${script//\//-}"
  mkdir -p "$work/home"

  set +e
  (
    cd "$work"
    HOME="$work/home" PATH="$mock_bin:$PATH" \
      timeout 30 bash "$ROOT/$script" </dev/null >"$work/stdout" 2>"$work/stderr"
  )
  status=$?
  set -e

  [[ $status -eq 1 ]] || fail "$script exits 1" "status $status: $(cat "$work/stderr")"
  grep -qF "$manual" "$work/stderr" || fail "$script points to the Mac manual on stderr" "$(cat "$work/stderr")"
  [[ ! -s $work/stdout ]] || fail "$script prints nothing else" "$(cat "$work/stdout")"
  [[ ! -s $calls ]] || fail "$script runs no command" "$(cat "$calls")"
  [[ -z $(ls -A "$work/home") ]] || fail "$script writes nothing to HOME" "$(ls -A "$work/home")"
  pass "$script refuses to start an install and changes nothing"
done

grep -qF 'sudo omarchy-mac-setup --abort' "$test_tmp/work-install.sh/stderr" ||
  fail "install.sh tells a guided setup in progress how to stop" "$(cat "$test_tmp/work-install.sh/stderr")"
pass "install.sh tells a guided setup in progress how to stop"
