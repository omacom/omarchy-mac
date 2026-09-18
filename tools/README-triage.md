# Jev triage workflow

This workflow classifies GitHub issues and proposes additive Omarchy labels and
cross-reference comments. Jev supplies typed judgments; the script owns
candidate retrieval, confidence thresholds, idempotency, and GitHub writes.

## Local preview

Install the SDK and provide the key through the environment, never in a file:

```sh
python3 -m pip install -r tools/requirements-triage.txt
export TYPESAFE_API_KEY='...'
export GITHUB_TOKEN='...'
python3 tools/jev_triage.py \
  --issue-json /path/to/issue.json \
  --prs-json /path/to/open-prs.json
```

Use `--offline` for deterministic tests without a TypeSafe request. The command
only writes to GitHub when `TRIAGE_APPLY=true`.

## GitHub Actions

Add `TYPESAFE_API_KEY` as a repository Actions secret. Run **Triage GitHub work**
from the Actions UI with an issue number. Keep `apply=false` while validating
the proposed judgments; enable it only after reviewing the step summary.

The workflow only adds labels and comments. It never replaces labels, closes
issues, or edits issue bodies. Rotate any key that has been pasted into chat or
committed accidentally.
