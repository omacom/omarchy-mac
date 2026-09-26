#!/bin/bash
# Checks the contracts of the MLX menu entry: the SoC gate must let through
# exactly the chips mlx-omarchy supports, it must not install over an
# existing installation, and when an install fails it must say what it
# actually cleaned up.
#
# The entry's failure path runs the upstream installer's --uninstall, which
# deletes every artifact unconditionally. Without the guard, a failed install
# over a working one removes the working one.
#
# Everything here runs against a disposable HOME with stub commands on PATH,
# so it needs no Apple hardware and installs nothing. Every stub is executable
# and proven to shadow the real command before anything runs, so no host -- a
# real M1 included -- can reach a real package transaction. The cases that
# need the real pinned installer skip themselves when there is no network.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/bin/omarchy-install-ai-mlx"

pass() { echo "✓ $*"; }
skip() { echo "- $* (skipped)"; }
fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "=== MLX install guards ==="
echo "Repo: $ROOT"

[[ -f $INSTALL ]] || fail "the install entry is missing"
bash -n "$INSTALL" || fail "the install entry does not parse"
pass "the install entry is present and parses"

work="$(mktemp -d)"
# $BIN is deliberately made unreadable by one case; restore it or the cleanup
# of the scratch directory fails too.
trap 'chmod -R u+rwX -- "$work" 2>/dev/null; rm -rf -- "$work"' EXIT

stub_dir="$work/stubs"
mkdir -p "$stub_dir"

# The entry gates on Apple hardware first; say yes, and present an M1 device
# tree, so the paths under test are the ones that run on a real M1.
printf '#!/bin/bash\nexit 0\n' >"$stub_dir/omarchy-hw-apple"
# The real pinned installer reaches omarchy-pkg-add on Apple hardware; stub
# it so a passing gate can never trigger a system-wide pacman transaction.
# Embed the log path because $work is not exported to the stub.
pkg_log="$work/pkg-add.log"
printf '#!/bin/bash\nprintf "%%s\\n" "omarchy-pkg-add $*" >>%q\nexit 0\n' "$pkg_log" >"$stub_dir/omarchy-pkg-add"
# Fail closed if the installer falls back to sudo pacman.
sudo_log="$work/sudo.log"
printf '#!/bin/bash\nprintf "%%s\\n" "sudo $*" >>%q\nexit 1\n' "$sudo_log" >"$stub_dir/sudo"
# Reach the package step on every host without building a real venv.
printf '#!/bin/bash\nif [[ ${1:-} == -m ]]; then echo aarch64; else exec /usr/bin/uname "$@"; fi\n' >"$stub_dir/uname"
printf '#!/bin/bash\nexit 0\n' >"$stub_dir/python3"
chmod +x "$stub_dir/omarchy-hw-apple" "$stub_dir/omarchy-pkg-add" "$stub_dir/sudo" "$stub_dir/uname" "$stub_dir/python3"
printf 'apple,j313\0apple,t8103\0' >"$work/compatible"

curl_log="$work/curl.log"

# Serves the cached installer instead of the network, honouring -o. Logs every
# call so a test can prove the entry refused before reaching the network.
make_curl_stub() {
  {
    echo '#!/bin/bash'
    echo 'printf "%s\n" "$*" >>"$CURL_LOG"'
    echo 'out=""; prev=""'
    echo 'for a in "$@"; do [[ $prev == -o ]] && out="$a"; prev="$a"; done'
    echo '[[ -n $out && -n ${INSTALLER_FIXTURE:-} ]] && cp -- "$INSTALLER_FIXTURE" "$out"'
    echo 'exit 0'
  } >"$stub_dir/curl"
  chmod +x "$stub_dir/curl"
}
make_curl_stub

# A non-executable stub would silently fall through to the real command.
for cmd in omarchy-hw-apple omarchy-pkg-add curl sudo uname python3; do
  [[ -x $stub_dir/$cmd ]] || fail "the $cmd stub is not executable"
  resolved="$(PATH="$stub_dir:$PATH" command -v "$cmd")" &&
    [[ $resolved == "$stub_dir/$cmd" ]] ||
    fail "$cmd would run '${resolved:-nothing}', not the stub"
done
pass "every stub is executable and shadows the real command on PATH"

# Runs the entry against the disposable HOME. Echoes its exit status; output is
# left in $work/out for the caller to inspect. The third argument overrides the
# device-tree compatible file, for the SoC gate cases.
run_entry() {
  local home="$1" prefix="$2" compat="${3:-$work/compatible}"
  local status=0
  : >"$curl_log"
  : >"$pkg_log"
  : >"$sudo_log"
  PATH="$stub_dir:$PATH" \
    HOME="$home" \
    MLX_OMARCHY_HOME="$prefix" \
    OMARCHY_APPLE_COMPATIBLE="$compat" \
    CURL_LOG="$curl_log" \
    INSTALLER_FIXTURE="${INSTALLER_FIXTURE:-}" \
    bash "$INSTALL" >"$work/out" 2>&1 || status=$?
  echo "$status"
}

echo
echo "=== the SoC gate follows mlx-omarchy's supported chips ==="

# The pinned installer accepts the M1 (t8103), the M1 Max (t6001), and the
# M2 Max (t6021); the entry must let exactly those through and skip anything
# else before it touches the network or the package manager.
for chips in 'apple,t8103' 'apple,t6001' 'apple,t6021' 'apple,t8112'; do
  printf 'apple,j313\0%s\0' "$chips" >"$work/compatible-gate"
  home="$work/home-gate-${chips/,/-}"
  prefix="$home/.local/share/mlx-omarchy"
  mkdir -p "$home/.local/bin" "$home/.local/share/applications"

  got="$(run_entry "$home" "$prefix" "$work/compatible-gate")"
  if [[ $chips == apple,t8112 ]]; then
    [[ $got == 0 ]] || fail "$chips: an unsupported SoC should skip cleanly, it exited $got"
    grep -q "Skipping: mlx-omarchy supports" "$work/out" ||
      fail "$chips: no skip message: $(cat "$work/out")"
    grep -q "$chips" "$work/out" ||
      fail "$chips: the skip should report the machine's SoC: $(cat "$work/out")"
    [[ ! -s $curl_log ]] ||
      fail "$chips: skipped only after fetching the installer: $(cat "$curl_log")"
    [[ ! -s $pkg_log ]] ||
      fail "$chips: skipped but omarchy-pkg-add ran: $(cat "$pkg_log")"
    pass "$chips: skips before any fetch or package work"
  else
    grep -q "Fetching the mlx-omarchy installer" "$work/out" ||
      fail "$chips: a supported SoC should install, it refused: $(cat "$work/out")"
    grep -q "raw.githubusercontent.com" "$curl_log" ||
      fail "$chips: the gate passed but no installer was fetched: $(cat "$curl_log")"
    [[ ! -s $pkg_log ]] ||
      fail "$chips: packages were installed before the installer was verified: $(cat "$pkg_log")"
    pass "$chips: passes the gate and fetches the pinned installer"
  fi
done

echo
echo "=== it refuses when an installation already exists ==="

# Each artifact on its own, because the installer's --uninstall deletes all
# seven and any one of them means something is already there. bin-info is the
# installed-state key the menu keys on, so it guards like the rest.
i=0
for artifact in prefix bin-launcher bin-demo bin-info bin-serve bin-omarchy-mlx-serve desktop-entry; do
  i=$((i + 1))
  home="$work/home$i"
  prefix="$home/.local/share/mlx-omarchy"
  mkdir -p "$home/.local/bin" "$home/.local/share/applications"
  case $artifact in
    prefix) mkdir -p "$prefix" && echo keep >"$prefix/marker" ;;
    bin-launcher) echo keep >"$home/.local/bin/mlx-omarchy" ;;
    bin-demo) echo keep >"$home/.local/bin/mlx-omarchy-demo" ;;
    bin-info) echo keep >"$home/.local/bin/mlx-omarchy-info" ;;
    bin-serve) echo keep >"$home/.local/bin/mlx-omarchy-serve" ;;
    bin-omarchy-mlx-serve) echo keep >"$home/.local/bin/omarchy-mlx-serve" ;;
    desktop-entry) echo keep >"$home/.local/share/applications/mlx-omarchy-demo.desktop" ;;
  esac

  got="$(run_entry "$home" "$prefix")"
  [[ $got != 0 ]] || fail "$artifact present: the entry should refuse, it exited 0"
  grep -q "already installed" "$work/out" ||
    fail "$artifact present: no explanation given: $(cat "$work/out")"
  grep -q "omarchy-remove-ai-mlx" "$work/out" ||
    fail "$artifact present: refusal should name how to remove it"
  [[ ! -s $curl_log ]] ||
    fail "$artifact present: refused only after fetching the installer: $(cat "$curl_log")"
  [[ ! -s $pkg_log ]] ||
    fail "$artifact present: refused but omarchy-pkg-add ran: $(cat "$pkg_log")"

  # The point of the guard: what was there is still there.
  case $artifact in
    prefix) [[ -f "$prefix/marker" ]] || fail "the existing installation was deleted" ;;
    bin-launcher) [[ -f "$home/.local/bin/mlx-omarchy" ]] || fail "the existing launcher was deleted" ;;
    bin-demo) [[ -f "$home/.local/bin/mlx-omarchy-demo" ]] || fail "the existing demo launcher was deleted" ;;
    bin-info) [[ -f "$home/.local/bin/mlx-omarchy-info" ]] || fail "the existing info launcher was deleted" ;;
    bin-serve) [[ -f "$home/.local/bin/mlx-omarchy-serve" ]] || fail "the existing serve launcher was deleted" ;;
    bin-omarchy-mlx-serve) [[ -f "$home/.local/bin/omarchy-mlx-serve" ]] || fail "the existing omarchy-mlx-serve fallback was deleted" ;;
    desktop-entry) [[ -f "$home/.local/share/applications/mlx-omarchy-demo.desktop" ]] || fail "the existing desktop entry was deleted" ;;
  esac
  pass "$artifact present: refuses before any change, and keeps it"
done

echo
echo "=== a failing install reports its own status ==="

fixture="$work/install.sh"
ref="$(grep -m1 '^INSTALLER_REF=' "$INSTALL" | cut -d'"' -f2)"
repo="$(grep -m1 '^INSTALLER_REPO=' "$INSTALL" | cut -d'"' -f2)"

if command -v curl >/dev/null &&
  /usr/bin/env curl -fsSL --max-time 20 \
    "https://raw.githubusercontent.com/$repo/$ref/install.sh" -o "$fixture" 2>/dev/null; then
  pass "fetched the pinned installer (${ref:0:12}) as a fixture"
  sha="$(grep -m1 '^INSTALLER_SHA256=' "$INSTALL" | cut -d'"' -f2)"
  echo "$sha  $fixture" | sha256sum -c --quiet - ||
    fail "the downloaded installer does not match the pinned checksum"
  pass "the fixture matches the pinned checksum"
  export INSTALLER_FIXTURE="$fixture"

  # The fixture served as SHA256SUMS contains no wheel, forcing failure.
  home="$work/home-fail"
  prefix="$home/.local/share/mlx-omarchy"
  mkdir -p "$home/.local/bin" "$home/.local/share/applications"

  got="$(run_entry "$home" "$prefix")"
  [[ $got != 0 ]] || fail "a failing install should not exit 0"
  grep -q "installation failed (exit $got)" "$work/out" ||
    fail "the failure message should name the real status: $(cat "$work/out")"
  if grep -q "installation failed (exit 0)" "$work/out"; then
    fail "the old bug is back: a real failure reported as exit 0"
  fi
  pass "a failing install exits $got and names that status"

  [[ $(cat "$pkg_log") == "omarchy-pkg-add lapack blas openblas" ]] ||
    fail "expected exactly 'omarchy-pkg-add lapack blas openblas', got: $(cat "$pkg_log")"
  pass "the runtime packages are requested through omarchy-pkg-add"
  [[ ! -s $sudo_log ]] || fail "the pacman fallback was reached: $(cat "$sudo_log")"
  pass "the pacman fallback was never reached"

  grep -q "Nothing from mlx-omarchy is left installed" "$work/out" ||
    fail "a successful cleanup should say so: $(cat "$work/out")"
  [[ ! -e $prefix ]] || fail "cleanup left $prefix behind"
  pass "cleanup ran and reported a clean machine"

  echo
  echo "=== a failing cleanup says so ==="

  # Same failing install, but with $HOME/.local/bin unreadable so the
  # uninstall's own rm cannot complete. The guard still passes because the
  # artifacts cannot be seen either.
  home="$work/home-dirty"
  prefix="$home/.local/share/mlx-omarchy"
  mkdir -p "$home/.local/bin" "$home/.local/share/applications"
  chmod 000 "$home/.local/bin"

  got="$(run_entry "$home" "$prefix")"
  chmod 755 "$home/.local/bin"

  if grep -q "Cleanup did not finish" "$work/out"; then
    [[ $got != 0 ]] || fail "a failed cleanup should still return the install's status"
    grep -q "omarchy-remove-ai-mlx" "$work/out" ||
      fail "a failed cleanup should say how to finish removing it"
    if grep -q "Nothing from mlx-omarchy is left installed" "$work/out"; then
      fail "it claimed a clean machine and a failed cleanup at once"
    fi
    pass "a failed cleanup is reported instead of claiming nothing remains"
  else
    # rm can still succeed here as root, which ignores the mode.
    if [[ $(id -u) -eq 0 ]]; then
      skip "running as root, so an unwritable directory does not fail rm"
    else
      fail "the failed-cleanup path was not reached: $(cat "$work/out")"
    fi
  fi
else
  skip "no network for the pinned installer, so the failure paths are not exercised"
fi

echo
echo "All MLX install guard checks passed."
