#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

bash "$TOOLS/evidence-verify" >"$test_tmp/out" 2>&1 || fail "the committed evidence verifies" "$(cat "$test_tmp/out")"
pass "the committed evidence is text-only and its artifacts are pinned"

if find "$TOOLS/evidence" -type f \( -name '*.gz' -o -name '*.tar' -o -name '*.zst' -o -name '*.iso' -o -name '*.img' \) | grep -q .; then
  fail "no archive or image is committed under evidence/"
fi
pass "no archive or image is committed under evidence/"

evidence="$test_tmp/evidence"
artifact_source="$test_tmp/published/state.tar.gz"
commit=0123456789abcdef0123456789abcdef01234567
reset_evidence() {
  rm -rf "$evidence"
  mkdir -p "$evidence/2026-09-25-m2-cold-boot" "$(dirname "$artifact_source")"
  printf '# M2 Max cold boot\n' >"$evidence/2026-09-25-m2-cold-boot/README.md"
  printf 'state\0archive\n' >"$artifact_source"
  printf '# path\tbytes\tsha256\turl\n2026-09-25-m2-cold-boot/state.tar.gz\t%s\t%s\thttps://raw.githubusercontent.com/owner/repo/%s/state.tar.gz\n' \
    "$(wc -c <"$artifact_source" | tr -d ' ')" "$(file_sha256 "$artifact_source")" "$commit" >"$evidence/artifacts.tsv"
}
verify() {
  OMARCHY_EVIDENCE_DIR="$evidence" bash "$TOOLS/evidence-verify" "$@" >"$test_tmp/out" 2>&1
}

reset_evidence
verify || fail "a well-formed record verifies" "$(cat "$test_tmp/out")"
pass "a record with a commit-pinned artifact verifies"

cp "$artifact_source" "$evidence/2026-09-25-m2-cold-boot/state.tar.gz"
verify && fail "a committed archive is refused"
grep -q "state.tar.gz is binary" "$test_tmp/out" || fail "the binary file is named" "$(cat "$test_tmp/out")"
grep -q "is also committed" "$test_tmp/out" || fail "the duplicate is named" "$(cat "$test_tmp/out")"
pass "a committed binary artifact is refused"

reset_evidence
head -c 70000 /dev/zero | tr '\0' 'a' >"$evidence/2026-09-25-m2-cold-boot/journal.txt"
verify && fail "a large text capture is refused"
grep -q "journal.txt is 70000 bytes" "$test_tmp/out" || fail "the large file is named" "$(cat "$test_tmp/out")"
pass "a text capture over 64 KiB is refused"

reset_evidence
sed -i.bak "s|/$commit/|/main/|" "$evidence/artifacts.tsv" && rm "$evidence/artifacts.tsv.bak"
verify && fail "a branch URL is refused"
grep -q "not pinned to a full commit" "$test_tmp/out" || fail "the unpinned URL is named" "$(cat "$test_tmp/out")"
pass "an artifact URL on a branch is refused"

reset_evidence
sed -i.bak 's|https://|http://|' "$evidence/artifacts.tsv" && rm "$evidence/artifacts.tsv.bak"
verify && fail "a plain http URL is refused"
pass "an artifact URL without https is refused"

# --fetch downloads through curl; serve the published file locally.
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/curl" <<'SH'
#!/bin/bash
out=""
while (( $# )); do
  case $1 in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) shift ;;
  esac
done
cp "$ARTIFACT_SOURCE" "$out"
SH
chmod +x "$stub_bin/curl"

reset_evidence
ARTIFACT_SOURCE="$artifact_source" PATH="$stub_bin:$PATH" verify --fetch || fail "a matching download verifies" "$(cat "$test_tmp/out")"
grep -q "1 artifacts downloaded and matched" "$test_tmp/out" || fail "the fetch is reported" "$(cat "$test_tmp/out")"
pass "--fetch downloads each artifact and matches its hash"

printf 'changed\n' >"$artifact_source"
ARTIFACT_SOURCE="$artifact_source" PATH="$stub_bin:$PATH" verify --fetch && fail "a changed download is refused"
grep -q "has SHA-256" "$test_tmp/out" || fail "the hash mismatch is named" "$(cat "$test_tmp/out")"
pass "--fetch refuses an artifact whose bytes changed"
