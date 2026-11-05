#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
cursor_dir="$test_tmp/cursor"
curl_log="$test_tmp/curl.log"
latest_version="3.20.17"
download_url="https://downloads.cursor.com/production/deadbeef/linux/arm64/Cursor-3.20.17-aarch64.AppImage"
mkdir -p "$stub_bin" "$cursor_dir"

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash
if [[ ${1:-} == "-m" ]]; then
  printf '%s\n' "${TEST_UNAME_M:-aarch64}"
  exit 0
fi
exec /usr/bin/uname "$@"
SH
chmod +x "$stub_bin/uname"

cat >"$stub_bin/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$CURL_LOG"

output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o | --output)
      output=$2
      shift 2
      ;;
    http*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ $url == *"/api/download"* ]]; then
  json=$(printf '{"version":"%s","downloadUrl":"%s"}\n' "$CURSOR_LATEST" "$CURSOR_DOWNLOAD_URL")
  if [[ -n $output ]]; then
    printf '%s' "$json" >"$output"
  else
    printf '%s' "$json"
  fi
  exit 0
fi

if [[ $url == "$CURSOR_DOWNLOAD_URL" ]]; then
  [[ -n $output ]] || exit 1
  printf 'appimage-bytes\n' >"$output"
  exit 0
fi

echo "unexpected curl url: ${url:-none}" >&2
exit 1
SH
chmod +x "$stub_bin/curl"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
chmod +x "$stub_bin/sudo"

run_update() {
  : >"$curl_log"
  CURL_LOG="$curl_log" \
    CURSOR_LATEST="$latest_version" \
    CURSOR_DOWNLOAD_URL="$download_url" \
    TEST_UNAME_M="${TEST_UNAME_M:-aarch64}" \
    OMARCHY_CURSOR_DIR="$cursor_dir" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-update-cursor" >"$test_tmp/out" 2>"$test_tmp/err"
}

run_update
[[ ! -s $curl_log ]] || fail "aarch64 without an AppImage does not contact Cursor" "$(cat "$curl_log")"
pass "aarch64 without an AppImage is a no-op"

printf 'old-bytes\n' >"$cursor_dir/cursor.AppImage"
TEST_UNAME_M=x86_64 run_update
[[ ! -s $curl_log ]] || fail "x86_64 does not contact Cursor" "$(cat "$curl_log")"
pass "x86_64 leaves Cursor to cursor-bin"

printf '%s\n' "$latest_version" >"$cursor_dir/version"
run_update
grep -F '/api/download' "$curl_log" >/dev/null ||
  fail "a current AppImage still checks the latest version" "$(cat "$curl_log")"
if grep -Fq -- "$download_url" "$curl_log"; then
  fail "a current AppImage is downloaded again" "$(cat "$curl_log")"
fi
[[ $(<"$cursor_dir/cursor.AppImage") == "old-bytes" ]] ||
  fail "a current AppImage is left in place"
pass "matching version skips the download"

printf '2.6.20\n' >"$cursor_dir/version"
run_update
[[ $(<"$cursor_dir/cursor.AppImage") == "appimage-bytes" ]] ||
  fail "an older AppImage is replaced" "$(cat "$cursor_dir/cursor.AppImage")"
[[ $(<"$cursor_dir/version") == "$latest_version" ]] ||
  fail "the installed version file is updated" "$(cat "$cursor_dir/version")"
pass "an older AppImage is replaced"

printf 'old-bytes\n' >"$cursor_dir/cursor.AppImage"
rm -f "$cursor_dir/version"
run_update
[[ $(<"$cursor_dir/cursor.AppImage") == "appimage-bytes" ]] ||
  fail "an AppImage without a version file is replaced"
[[ $(<"$cursor_dir/version") == "$latest_version" ]] ||
  fail "a missing version file is written after the download"
pass "a missing version file is treated as outdated"

if grep -Fq 'VERSION="2.6.20"' "$ROOT/bin/omarchy-install-cursor"; then
  fail "the aarch64 installer still pins Cursor 2.6.20"
fi
grep -Fq 'platform=linux-arm64&releaseTrack=latest' "$ROOT/bin/omarchy-install-cursor" ||
  fail "the aarch64 installer does not fetch the current Cursor release"
grep -Fq '$CURSOR_VERSION_FILE' "$ROOT/bin/omarchy-install-cursor" ||
  fail "the aarch64 installer does not record the installed version"
pass "the aarch64 installer fetches current Cursor and records its version"
