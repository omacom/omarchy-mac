# E2E evidence collector (`scripts/collect_e2e.py`)

Companion to `docs/omarchy-mac-e2e-volunteer-checklist.md`. The checklist
names what a volunteer must observe; the collector gathers everything a
machine can observe, redacts identity strings, and packs the result into a
reviewable archive a volunteer attaches to their test report.

## Why

The checklist's report template asks for machine details, stage-by-stage
results, logs, and security-cleanup evidence. Today volunteers gather all
of that by hand and the reports arrive inconsistent (the M1 iMac E2E run
showed what that costs). The mlx-omarchy project already solved this class
of problem with consent-gated, redacted, deterministic evidence collectors;
this brings the same machinery to the Mac installer checklist.

## What it collects

| Section | Checklist coverage | Method |
|---|---|---|
| `identity` | §1 test assignment | interactive prompts, reused from `./e2e-identity.json` (written back after an interactive run), plus machine-recorded identity: marketing model, board and SoC from devicetree compatible strings, kernel, OS, collection date. Identity only — never a feature verdict |
| `baseline` | §3 fresh-Asahi baseline | the exact documented commands, plus derived facts: LUKS present, `/boot` separate, freshness marker |
| `mlx` | — (bonus) | the mlx-omarchy quick capability report: host/devicetree, Mesa/Vulkan, ANE devicetree, installed distributions. A missing `vulkaninfo` records `probe: missing` — it never reads as an unsupported GPU |
| `hardware` | hardware matrix evidence | presence-only records for the wiki features: DRM connectors, audio cards, USB, Thunderbolt, wireless, Bluetooth, cameras, input devices, suspend states. Presence is never converted into "working" |
| `install-logs` | §4–5 | tails of the three documented logs (a missing log records *why* it can be absent — absence is data, never a hardware failure) plus `journalctl -u omarchy-mac-setup.service`, `omarchy-mac-setup --status`, service state |
| `boot` | §5–7 | `journalctl --list-boots`, current-boot warnings, failed system and user units, `/boot` tree |
| `install-state` | §6 | omarchy version/path, pinned packages, `pacman -Dk`, `omarchy-migrate --pending` (exit semantics recorded, never interpreted), `omarchy-done` checks, swap |
| `security` | §7 | setup conf/sudoers presence, passwordless-sudo probe, sshd exposure, nft ruleset, user journal warnings |
| `macos` | §2–3 | optional: pasted macOS-side output via `--from-macos FILE` |
| `interview` | §5–9 human items + wiki hardware matrix | `--interview` walks all 34 judgment checkboxes (PASS/FAIL/SKIP/NA) and 18 per-feature hardware answers (WORKS/LIMITATION/BROKEN/UNKNOWN/NA, one per Apple-Silicon-hardware.md matrix column, with the peripheral model and connection in the note). Persisted to `./e2e-answers.json` |

Stage verdicts in the report roll up honestly: a stage answered entirely NA
renders `NA` (the stage does not exist on a `--no-encrypt` run, for example),
and a PASS+SKIP mix renders `PARTIAL` — never `SKIP`, which would claim the
stage went untested.

Every external command is bounded (timeout, capped output); a missing tool
or absent log is recorded as data, never a crash; partial runs keep what
finished. Every captured value passes the shared redactor (usernames,
hostnames, home paths, IPs, MACs, serials, credential-shaped strings), and
the per-kind redaction counts ship in the manifest.

## Volunteer flow

Before this PR merges, fetch the wrapper from the PR branch:

```bash
curl -fsSL https://raw.githubusercontent.com/joshuaswarren/omarchy-mac/e2e-collector/bin/omarchy-mac-e2e-collect -o e2e-collect
bash e2e-collect --interview --out e2e-<testid>.tar.gz
```

The wrapper tries `quattro` first, falls back to this branch when the collector is not merged yet, and prints which tree served the files. After merge the same two commands work unchanged. From a checkout, `python3 scripts/collect_e2e.py --interview --out e2e-<testid>.tar.gz` runs the same collector.

That prints a preview manifest, then writes:

- `e2e-<testid>.tar.gz` — deterministic archive (all section JSON, the
  checklist itself, the pre-filled report template with the per-feature
  hardware matrix)
- `e2e-<testid>.submission.md` — paste-ready cover: machine identity,
  derived storage facts, redaction summary, and the checklist report
  template auto-filled where the machine could answer

Attach both to the test ID / tracking issue. Nothing is uploaded unless
`--submit URL` is passed (community-data worker protocol, kind
`omarchy-mac-e2e`; the live worker accepts this kind as of 2026-09-18 —
sample record:
https://mlx-omarchy-community-data.joshua-s-warren.workers.dev/v1/results/ef89a1c651ce3cb599be62dc7baa49f8bacb5e76e9e3a56d41b0fddd60627ff3).

## Provenance

The four helpers (`collect_common.py`, `collect_submit.py`, `collect_quick.py`, and `collect_macos.py`) originate from `joshuaswarren/mlx-omarchy`. Local changes keep the macOS helper self-contained and distinguish a missing Vulkan probe from an unavailable GPU.

## Verification

- `python3 tests/test-collect-e2e.py` — focused stdlib-only regression
  checks: stage-verdict roll-ups (all-NA → NA, PASS+SKIP → PARTIAL), the
  probe-missing Vulkan summary, log-absence wording, per-feature answer
  separation (old combined-question PASS never transfers to a split
  feature; hand-written `ANSWER; note` values load normalized), wiki
  symbol rendering, and archive/submission preservation of feature
  answers.
- A real terminal interview checks all 67 prompts, persists answers, and verifies that first-run identity and feature results reach the archive. Without `--interview`, collection never prompts. These checks run on Linux x86_64; they do not establish Apple hardware compatibility.
- `bun test` (worker side, mlx-omarchy): 67/67 unit, including the new
  e2e-kind schema fixture and a smoke scenario; live worker deployed and
  `check_schema_identity.py` green.
- Collector exercised end to end on a non-Apple x86_64 host: every
  section records (unavailability is data), redaction counts present,
  archive + submission built; live submit round-tripped through the
  worker and is served at the sample URL above.

## Notes for reviewers

- The dashboard (community-data worker) now shows a Kind column so e2e
  reports are distinguishable from mlx-omarchy quick/deep rows.
- `--submit` is opt-in per run; the default writes local files only.
- The e2e payload adds six nullable summary fields
  (`test_id`, `install_path`, `asahi_image`, `encryption`,
  `boot_separate`, `overall`) to the community-data schema; old
  collectors are unaffected and the fields are optional.
