#!/usr/bin/env bash
set -euo pipefail

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

cat > "$test_dir/issue.json" <<'JSON'
{"number": 99, "title": "Wi-Fi fails after resume", "body": "Network does not recover after sleep.", "labels": []}
JSON
cat > "$test_dir/prs.json" <<'JSON'
[{"number": 101, "title": "Fix Wi-Fi resume recovery", "body": "Reload the wireless driver after resume."}]
JSON

result=$(python3 tools/jev_triage.py --offline --issue-json "$test_dir/issue.json" --prs-json "$test_dir/prs.json")
grep -q '"subsystem": "network"' <<<"$result"
grep -q '"related_pr": 101' <<<"$result"
grep -q '"core_userspace": 0.51' <<<"$result"

printf 'jev triage offline test: ok\n'
