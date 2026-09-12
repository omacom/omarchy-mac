#!/usr/bin/env python3
"""RED/GREEN gates against pinned source; network needed unless --source is set.

Only a temporary directory is modified. --source reads baseline blobs from Git,
not the worktree, and checks their hashes just like the downloaded files.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

BASE = "ce9f2eba72c061a50b2d790450e90af3439d8c24"
HERE = Path(__file__).resolve().parent
PATCH = HERE.parents[1] / "patches/asahi/apple-dcp-hdmi-reconnect.patch"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, help="existing Git repository containing the pinned baseline")
args = parser.parse_args()
manifest = json.loads((HERE / "baseline-sha256.json").read_text())

with tempfile.TemporaryDirectory(prefix="asahi-reconnect-") as directory:
  root = Path(directory)
  for path, digest in manifest.items():
    if args.source:
      content = subprocess.check_output(["git", "-C", str(args.source), "show", f"{BASE}:{path}"])
    else:
      url = f"https://raw.githubusercontent.com/AsahiLinux/linux/{BASE}/{path}"
      with urllib.request.urlopen(url, timeout=60) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != digest:
      raise SystemExit(f"Baseline checksum mismatch: {path}")
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)

  def run(*command, **kwargs):
    return subprocess.run(command, cwd=root, check=True, **kwargs)

  run("git", "init", "-q")
  run("git", "add", "drivers")
  run("git", "-c", "user.name=Regression fixture", "-c", "user.email=fixture@example.invalid",
      "-c", "commit.gpgsign=false", "commit", "-qm", "Verified pinned source fixture")
  env = dict(os.environ, ASAHI_TEST_SOURCE=str(root))
  # A compiler or download failure must never count as the expected RED result.
  red = subprocess.run(["python3", str(HERE / "run_c_seam_tests.py"), "--baseline"],
                       cwd=root, env=env, text=True, capture_output=True)
  print(red.stdout, end="")
  if red.returncode != 1 or "C seam regression: RED (11 failures)" not in red.stdout:
    raise SystemExit(f"Unexpected baseline result:\n{red.stderr}")
  run("git", "apply", "--check", str(PATCH))
  run("git", "apply", str(PATCH))
  run("git", "diff", "--check")
  run("python3", str(HERE / "test_reconnect.py"), env=env)
  run("python3", str(HERE / "run_c_seam_tests.py"), env=env)
  print("VERDICT: PASS — pinned patch applies, baseline RED, patched source and C seam GREEN")
