#!/usr/bin/env python3
"""Confidence-gated GitHub triage for Omarchy Mac.

The classifier is deliberately separate from GitHub writes.  By default this
script produces a preview; set TRIAGE_APPLY=true only after reviewing it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


REPO = os.environ.get("GITHUB_REPOSITORY", "omacom/omarchy-mac")
API = "https://api.github.com"
CORE = {
    "display", "audio", "video", "graphics", "gpu", "memory", "storage",
    "battery", "keyboard", "network", "bluetooth", "wifi", "wireless",
}
TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9_-]{2,}")


@dataclass
class Decision:
    subsystem: str
    subsystem_confidence: float
    core_userspace: float
    related_pr: int | None
    related_pr_probability: float
    duplicate: float


def github(path: str, token: str, *, method: str = "GET", body: Any = None) -> Any:
    request = urllib.request.Request(
        API + path,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        data=json.dumps(body).encode() if body is not None else None,
    )
    if body is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def words(text: str) -> set[str]:
    return set(TOKEN_RE.findall(text.lower()))


def candidates_for(issue: dict[str, Any], prs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    issue_words = words(f"{issue.get('title', '')} {issue.get('body', '')}")
    issue_number = issue["number"]
    ranked: list[tuple[int, dict[str, Any]]] = []
    for pr in prs:
        text = f"{pr.get('title', '')} {pr.get('body', '')}"
        score = len(issue_words & words(text))
        if re.search(rf"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#?{issue_number}\b", text, re.I):
            score += 100
        if score:
            ranked.append((score, pr))
    ranked.sort(key=lambda item: (-item[0], item[1]["number"]))
    return [pr for _, pr in ranked[:8]]


def deterministic_decision(issue: dict[str, Any], candidates: list[dict[str, Any]]) -> Decision:
    """Offline fallback used by tests and preview environments without a key."""
    text = f"{issue.get('title', '')} {issue.get('body', '')}".lower()
    hits = [name for name in sorted(CORE) if name in text]
    subsystem = hits[0] if hits else "other"
    related = candidates[0] if candidates else None
    return Decision(
        subsystem=subsystem,
        subsystem_confidence=0.51 if hits else 0.99,
        core_userspace=0.51 if hits else 0.01,
        related_pr=related["number"] if related else None,
        related_pr_probability=0.51 if related else 0.01,
        duplicate=0.01,
    )


def jev_decision(issue: dict[str, Any], candidates: list[dict[str, Any]]) -> Decision:
    try:
        from typesafe_sdk import Choice, Noul, TypeSafeClient
    except ImportError as exc:
        raise RuntimeError("Install typesafe-sdk or use --offline") from exc

    candidate_names = {f"pr_{pr['number']}": None for pr in candidates}
    candidate_names["none"] = None
    state = {
        "issue": {
            "number": issue["number"],
            "title": issue.get("title", ""),
            "body": issue.get("body", ""),
            "labels": [label["name"] for label in issue.get("labels", [])],
        },
        "candidate_open_prs": [
            {"number": pr["number"], "title": pr.get("title", ""), "body": pr.get("body", "")}
            for pr in candidates
        ],
    }
    subsystem_options = {name: None for name in sorted(CORE | {
        "installer", "packaging", "migration", "ci", "documentation", "other"
    })}
    with TypeSafeClient(model="jev") as client:
        result = client.system_one(
            state=state,
            questions={
                "subsystem": Choice(
                    instructions="Which single subsystem best describes the issue's primary behavior?",
                    criteria=subsystem_options,
                ),
                "core_userspace": Noul(
                    instructions="Does this issue primarily affect display, audio, video, graphics, memory, storage, battery, keyboard, network, or Bluetooth behavior?"
                ),
                "related_pr": Choice(
                    instructions="Which candidate open PR addresses the issue's underlying problem, not merely a shared keyword?",
                    criteria=candidate_names,
                ),
            },
        )
    subsystem_answer = result.choices["subsystem"]
    related_answer = result.choices["related_pr"]
    related = related_answer.choice
    return Decision(
        subsystem=subsystem_answer.choice,
        subsystem_confidence=float(subsystem_answer.confidence),
        core_userspace=float(result.nouls["core_userspace"].noul),
        related_pr=int(related.removeprefix("pr_")) if related != "none" else None,
        related_pr_probability=max(
            (float(p) for key, p in related_answer.probabilities.items() if key == related),
            default=0.0,
        ),
        duplicate=0.0,
    )


def issue_comments(issue: dict[str, Any], token: str) -> list[dict[str, Any]]:
    return github(f"/repos/{REPO}/issues/{issue['number']}/comments?per_page=100", token)


def apply_decision(issue: dict[str, Any], decision: Decision, token: str) -> list[str]:
    actions: list[str] = []
    labels = {label["name"] for label in issue.get("labels", [])}
    comments = issue_comments(issue, token)
    if decision.core_userspace >= 0.85 and "lvl 0" not in labels:
        github(f"/repos/{REPO}/issues/{issue['number']}/labels", token, method="POST", body={"labels": ["lvl 0"]})
        actions.append("added lvl 0")
    if decision.related_pr and decision.related_pr_probability >= 0.85:
        if "WIP" not in labels:
            github(f"/repos/{REPO}/issues/{issue['number']}/labels", token, method="POST", body={"labels": ["WIP"]})
            actions.append("added WIP")
        marker = f"Related open PR: #{decision.related_pr}"
        if not any(marker in comment.get("body", "") for comment in comments):
            body = f"{marker} — https://github.com/{REPO}/pull/{decision.related_pr}"
            github(f"/repos/{REPO}/issues/{issue['number']}/comments", token, method="POST", body={"body": body})
            actions.append(f"commented PR #{decision.related_pr}")
    return actions


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--issue-json", required=True)
    parser.add_argument("--prs-json", required=True)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    issue = json.load(open(args.issue_json, encoding="utf-8"))
    prs = json.load(open(args.prs_json, encoding="utf-8"))
    candidates = candidates_for(issue, prs)
    decision = deterministic_decision(issue, candidates) if args.offline else jev_decision(issue, candidates)
    payload = {"issue": issue["number"], "candidates": [p["number"] for p in candidates], "decision": decision.__dict__}
    token = os.environ.get("GITHUB_TOKEN")
    if os.environ.get("TRIAGE_APPLY", "false").lower() == "true":
        if not token:
            raise SystemExit("TRIAGE_APPLY=true requires GITHUB_TOKEN")
        payload["actions"] = apply_decision(issue, decision, token)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
