#!/usr/bin/env python3
"""Focused regression checks for the Mac E2E collector (stdlib only).

Run: python3 tests/test-collect-e2e.py

Covers the behaviours reviewers actually caught on PR464 and the wiki
feature-matrix contract:

- stage verdicts: all-NA renders NA, PASS+SKIP renders PARTIAL (never SKIP)
- Vulkan summary: a missing vulkaninfo probe says "probe missing", not
  "unavailable"
- install-log absence notes say absence is not a hardware failure
- the interview keeps one answer per wiki hardware feature, preserves
  persisted old answers (including combined-question keys from older
  collectors), and never transfers an old combined PASS to a split feature
- feature answers render as the wiki matrix symbols with their
  peripheral/connection notes, and unrecorded features stay '?'
- machine identity records model/board/SoC/kernel/date without crashing
  off-Apple, and the archive/submission carry the feature answers
"""

import builtins
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "scripts"))

import collect_e2e  # noqa: E402
import collect_quick  # noqa: E402
from collect_common import Redactor  # noqa: E402

FAILURES = []


def check(name, fn, tmp=None):
    try:
        fn(tmp)
    except AssertionError as exc:
        FAILURES.append(f"{name}: {exc}")
        print(f"✗ {name}: {exc}")
    except Exception as exc:  # noqa: BLE001
        FAILURES.append(f"{name}: unexpected {type(exc).__name__}: {exc}")
        print(f"✗ {name}: unexpected {type(exc).__name__}: {exc}")
    else:
        print(f"✓ {name}")


def answers_for(mapping):
    return {f"{g}::{i}": a for (g, i), a in mapping.items()}


def group_items(group):
    return [i for g, i in collect_e2e.INTERVIEW_ITEMS if g == group]


# The wiki hardware matrix columns, verbatim from
# Apple-Silicon-hardware.md; the collector must cover every one.
WIKI_FEATURES = [
    "internal display", "HDMI display", "USB-C DisplayPort display",
    "USB devices", "Thunderbolt dock", "Wi-Fi", "Bluetooth",
    "speakers", "headphones", "microphone", "HDMI audio",
    "suspend", "camera", "Touch ID", "keyboard", "trackpad",
    "GPU inference", "Neural Engine",
]


def test_stage_verdicts(_=None):
    v = collect_e2e.stage_verdict
    # PR464 case 1: --no-encrypt run, encryption stages all NA -> NA.
    all_na = {("reboot-b", i): "NA" for i in group_items("reboot-b")}
    assert v(answers_for(all_na), "reboot-b") == "NA", \
        "all-NA stage must be NA, not PARTIAL"
    # PR464 case 2: 10 PASS + 1 SKIP -> PARTIAL, never SKIP.
    desktop = group_items("desktop")
    mixed = {("desktop", i): "PASS" for i in desktop[:-1]}
    mixed[("desktop", desktop[-1])] = "SKIP"
    assert v(answers_for(mixed), "desktop") == "PARTIAL", \
        "PASS+SKIP mix must be PARTIAL, not SKIP"
    # FAIL dominates; all PASS passes; all SKIP stays SKIP; NA among
    # passes is ignored; nothing recorded is UNRECORDED.
    full_pass = {("desktop", i): "PASS" for i in desktop}
    first = {("desktop", desktop[0])}
    assert v(answers_for({**full_pass, ("desktop", desktop[0]): "FAIL"}),
             "desktop") == "FAIL"
    assert v(answers_for(full_pass), "desktop") == "PASS"
    assert v(answers_for({("desktop", i): "SKIP" for i in desktop}),
             "desktop") == "SKIP"
    assert v(answers_for({**full_pass, next(iter(first)): "NA"}),
             "desktop") == "PASS"
    assert v({}, "desktop") == "UNRECORDED"


def test_parse_answer_vocabularies(_=None):
    parse = collect_e2e.parse_answer
    got = parse("WORKS; Dell U2723QE via USB-C", "",
                collect_e2e.FEATURE_ANSWERS)
    assert got == ("WORKS", "Dell U2723QE via USB-C")
    # A stage answer is not valid for a feature and vice versa.
    assert parse("PASS", "", collect_e2e.FEATURE_ANSWERS) == (None, None)
    assert parse("WORKS", "", collect_e2e.VALID_ANSWERS) == (None, None)
    # Blank keeps the prior answer; case and whitespace tolerated.
    assert parse("", "LIMITATION", collect_e2e.FEATURE_ANSWERS) == \
        ("LIMITATION", None)
    assert parse(" works ", "", collect_e2e.FEATURE_ANSWERS) == ("WORKS", None)


def test_feature_contract(_=None):
    assert list(collect_e2e.FEATURE_ITEMS) == WIKI_FEATURES, \
        "collector features must match the wiki hardware matrix exactly"
    assert set(collect_e2e.FEATURE_PERIPHERAL) <= set(WIKI_FEATURES)


def test_split_answers_preserve_old_and_transfer_nothing(tmp):
    """Persisted old answers survive; the old combined PASS does not
    become a split feature's answer."""
    path = os.path.join(tmp, "e2e-answers.json")
    combined = ("desktop::Audio plays at modest volume with speaker "
                "protection active")
    with open(path, "w") as fh:
        json.dump({"answers": {combined: "PASS",
                               "some-future-key": "kept-verbatim",
                               "hardware::headphones":
                                   "WORKS;Sennheiser HD 560S via 3.5mm jack"}},
                  fh)
    real_stdin, real_input = sys.stdin, builtins.input

    class FakeTTY:
        def isatty(self):
            return True

    # 34 checklist items accept blank; then the first feature gets an
    # invalid stage answer (reprompt) then BROKEN; the second gets
    # WORKS plus a peripheral note; the rest stay blank.
    script = iter([""] * len(collect_e2e.INTERVIEW_ITEMS)
                  + ["PASS", "BROKEN",
                     "WORKS;AOC U27P2CA via USB-C DP"] + [""] * 100)
    sys.stdin = FakeTTY()
    builtins.input = lambda *a, **k: next(script)
    try:
        out = collect_e2e.section_interview(Redactor(), path)
    finally:
        sys.stdin, builtins.input = real_stdin, real_input
    answers = out["answers"]
    assert answers[combined] == "PASS", "old combined answer must survive"
    assert answers["some-future-key"] == "kept-verbatim", \
        "unknown keys must be preserved, not pruned"
    assert answers["hardware::internal display"] == "BROKEN"
    assert answers["hardware::HDMI display"] == "WORKS"
    # Old combined PASS never leaks into the split features.
    assert "hardware::speakers" not in answers, \
        "split feature must start unanswered, not inherit the combined PASS"
    # A hand-written "ANSWER; note" value loads normalized, not verbatim.
    assert answers["hardware::headphones"] == "WORKS"
    assert out["notes"]["hardware::headphones"] == \
        "Sennheiser HD 560S via 3.5mm jack"
    # Peripheral model/connection note retained.
    assert out["notes"]["hardware::HDMI display"] == \
        "AOC U27P2CA via USB-C DP"
    # Write-back preserves everything, including keys this version
    # does not know.
    with open(path) as fh:
        saved = json.load(fh)["answers"]
    assert saved[combined] == "PASS"
    assert saved["some-future-key"] == "kept-verbatim"


def test_feature_matrix_render(_=None):
    answers = {"hardware::speakers": "WORKS",
               "hardware::suspend": "LIMITATION",
               "hardware::Touch ID": "BROKEN",
               "hardware::HDMI display": "NA",
               "hardware::microphone": "UNKNOWN"}
    notes = {"hardware::HDMI display": "Dell U2723QE via HDMI 2.0"}
    text = "\n".join(collect_e2e.render_feature_matrix(answers, notes))
    assert "speakers: WORKS (✓)" in text
    assert "suspend: LIMITATION (!)" in text
    assert "Touch ID: BROKEN (✕)" in text
    assert "HDMI display: NA (n/a) — Dell U2723QE via HDMI 2.0" in text
    assert "microphone: UNKNOWN (?)" in text
    # Unrecorded renders '?' (not known), never a machine-derived verdict.
    assert "Wi-Fi: UNRECORDED (?)" in text
    assert "camera: UNRECORDED (?)" in text


def test_vulkan_probe_missing_reads_honest(_=None):
    missing = {"mesa": {"available": False, "probe": "missing",
                        "vulkaninfo": {"available": False,
                                       "error": "not-found"}}}
    line = collect_e2e.vulkan_summary(missing)
    assert "probe missing" in line, "absent tool must say probe missing"
    assert "not a GPU or driver verdict" in line
    # Driver-package fallback gives real signal when the tool is absent.
    fallback = {"mesa": missing["mesa"],
                "mesa_package": {"vulkan-asahi": {
                    "exit_code": 0, "stdout": "vulkan-asahi 1:26.2.3-1"}}}
    assert "vulkan-asahi 1:26.2.3-1" in collect_e2e.vulkan_summary(fallback)
    ok = {"mesa": {"gpu": {"deviceName": "Apple M2 Pro (G13C)",
                           "driverName": "Honeykrisp"}}}
    line = collect_e2e.vulkan_summary(ok)
    assert "Apple M2 Pro (G13C)" in line and "Honeykrisp" in line


def test_log_absence_is_not_failure(_=None):
    empty = {"logs": {p: {"present": False}
                      for p in collect_e2e.SETUP_LOGS}}
    line = collect_e2e.logs_presence_line(empty)
    assert "not a hardware" in line and "absence_notes" in line
    some = {"logs": {"/var/log/pacman.log": {"present": True},
                     "/var/log/omarchy-mac-setup.log": {"present": False}}}
    assert collect_e2e.logs_presence_line(some) == \
        "Install logs present: /var/log/pacman.log"
    # The never-written setup log carries its own why-note in the section.
    assert "never writes this file" in collect_e2e.LOG_ABSENCE_NOTES[
        "/var/log/omarchy-mac-setup.log"]


def test_machine_identity_anywhere(_=None):
    ident = collect_e2e.machine_identity()
    for key in ("marketing_model", "board_compatible", "soc", "compatible",
                "kernel", "os", "collected_at_utc"):
        assert key in ident
    # Off-Apple this host has no apple,t* / apple,j* strings; None is
    # data, not a crash.
    assert ident["soc"] is None or ident["soc"].startswith("T")
    assert ident["collected_at_utc"].endswith("Z")


def test_collect_quick_probe_state(_=None):
    # collect() accepts probe overrides; the missing-tool state must be
    # explicit so downstream never calls it "unsupported".
    report = collect_quick.collect(probes={
        "mesa": lambda redactor: {
            "available": False, "probe": "missing",
            "vulkaninfo": {"available": False, "error": "not-found"}}})
    assert report["mesa"]["probe"] == "missing"


def test_report_and_submission_carry_features(tmp):
    answers = {"hardware::speakers": "WORKS",
               "hardware::suspend": "LIMITATION",
               "hardware::Touch ID": "BROKEN"}
    notes = {"hardware::suspend": "resumes, Wi-Fi needs rmmod/modprobe"}
    interview = {"available": True, "answers": answers, "notes": notes,
                 "interactive": True}
    identity = {"test_id": "T-1"}
    files = {"interview.json": json.dumps(interview).encode(),
             "identity.json": json.dumps({"available": True, "machine": {
                 "marketing_model":
                     "Apple MacBook Pro (16-inch, M2 Pro, 2023)",
                 "board_compatible": "apple,j416s", "soc": "T6020",
                 "os": "Arch Linux", "kernel": "6.17.0",
                 "collected_at_utc": "2026-09-19T00:00:00Z"}}).encode(),
             "baseline.json": json.dumps(
                 {"storage_facts": {"root_encrypted": True}}).encode(),
             "install-state.json": b"{}",
             "security.json": b"{}",
             "mlx.json": json.dumps({
                 "host": {"devicetree": {"model": "Apple MacBook Pro"}},
                 "mesa": {"available": False, "probe": "missing",
                          "vulkaninfo": {"available": False,
                                         "error": "not-found"}}}).encode()}
    report = collect_e2e.render_report_md(identity, files)
    for needle in ("speakers: WORKS (✓)", "suspend: LIMITATION (!)",
                   "Touch ID: BROKEN (✕)",
                   "Wi-Fi: UNRECORDED (?)",
                   "note [hardware::suspend]: resumes, Wi-Fi needs "
                   "rmmod/modprobe",
                   "apple,j416s", "T6020", "Machine [auto]:"):
        assert needle in report, f"report must carry {needle!r}"
    submission = collect_e2e.build_submission({}, files, identity)
    assert "probe missing" in submission
    assert "speakers: WORKS (✓)" in submission, \
        "submission.md must preserve feature answers"


def test_connector_names(_=None):
    import io
    from unittest.mock import patch

    names = ["card0", "renderD128", "card0-HDMI-A-1", "card0-DP-1", "card0-eDP-1"]
    with patch.object(collect_e2e.os, "listdir", side_effect=lambda path: names if path == "/sys/class/drm" else []), \
         patch.object(collect_e2e.os.path, "isdir", return_value=True), \
         patch("builtins.open", side_effect=lambda *args, **kwargs: io.StringIO("connected")), \
         patch.object(collect_e2e, "tool", return_value={}):
        result = collect_e2e.section_hardware(Redactor())
    assert {row["connector"] for row in result["drm_connectors"]} == set(names[2:])


def test_invalid_or_missing_answers_do_not_pass(_=None):
    keys = [f"desktop::{item}" for item in group_items("desktop")]
    answers = dict.fromkeys(keys, "PASS")
    answers[keys[0]] = "WORKS"
    assert collect_e2e.stage_verdict(answers, "desktop") == "PARTIAL"
    assert collect_e2e.stage_verdict({keys[0]: "garbage"}, "desktop") == "UNRECORDED"
    assert collect_e2e.stage_verdict({keys[0]: "PASS"}, "desktop") == "PARTIAL"
    text = "\n".join(collect_e2e.render_feature_matrix({"hardware::speakers": "PASS"}, {}))
    assert "speakers: UNRECORDED (?)" in text


def test_console_interview_reaches_archive(tmp):
    import pty
    import select
    import subprocess
    import tarfile
    import time

    master, slave = pty.openpty()
    archive = os.path.join(tmp, "console.tar.gz")
    command = [sys.executable, collect_e2e.__file__, "--interview", "--out", archive,
               "--identity-file", os.path.join(tmp, "console-identity.json"),
               "--answers-file", os.path.join(tmp, "console-answers.json"),
               "--skip", ",".join(s for s in collect_e2e.SECTION_ORDER
                                 if s not in ("identity", "interview"))]
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    pending = b""
    prompts = 0
    deadline = time.monotonic() + 20
    try:
        while process.poll() is None and time.monotonic() < deadline:
            if not select.select([master], [], [], 0.1)[0]:
                continue
            try:
                pending += os.read(master, 65536)
            except OSError:
                break
            if pending.endswith(b": "):
                if prompts == 0:
                    answer = "ConsoleTester"
                elif prompts == 1:
                    answer = "CONSOLE-464"
                elif b"[hardware] speakers" in pending:
                    answer = "WORKS; built-in speakers"
                elif prompts >= 15:
                    answer = "NA"
                else:
                    answer = ""
                os.write(master, (answer + "\n").encode())
                prompts += 1
                pending = b""
        assert process.wait(timeout=2) == 0
        assert prompts == 67, f"expected visible identity and interview prompts, got {prompts}"
        with tarfile.open(archive) as tar:
            cover = tar.extractfile("submission.md")
            answers = tar.extractfile("interview.json")
            assert cover is not None and answers is not None
            submission = cover.read().decode()
            interview = json.load(answers)
        assert "CONSOLE-464" in submission
        assert "ConsoleTester" in submission
        assert interview["answers"]["hardware::speakers"] == "WORKS"
        assert "speakers: WORKS" in submission
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        os.close(master)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        for name in sorted(n for n in globals() if n.startswith("test_")):
            check(name, globals()[name], tmp)
    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
