#!/usr/bin/env python3
"""Checks for the MacBook support matrix generator (stdlib only).

Run: python3 tests/test-macbook-support-matrix.py
"""

import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "scripts", "macbook-support-matrix"))

import matrix  # noqa: E402


def read(path):
    with open(path) as f:
        return f.read()


class LinkTest(unittest.TestCase):
    def test_repo_and_bare_numbers(self):
        out = matrix.link("in linux-aurora#404 and m1n1#30, #33")
        self.assertIn('href="https://github.com/omacom/linux-aurora/pull/404">linux-aurora#404</a>', out)
        self.assertIn('href="https://github.com/omacom/m1n1/pull/30">m1n1#30</a>', out)
        self.assertIn('href="https://github.com/omacom/m1n1/pull/33">#33</a>', out)

    def test_bare_number_defaults_to_kernel(self):
        self.assertIn("linux-aurora/pull/274", matrix.link("before #274"))

    def test_existing_links_and_entities_untouched(self):
        a = '<a href="https://github.com/omacom/mesa/pull/33">mesa#33</a>'
        out = matrix.link(a + " then #34")
        self.assertTrue(out.startswith(a + " then <a "))
        self.assertIn("mesa/pull/34", out)
        self.assertEqual(matrix.link("it&#39;s"), "it&#39;s")


class ExpandTest(unittest.TestCase):
    def setUp(self):
        self.data = matrix.load_data(os.path.join(ROOT, "scripts", "macbook-support-matrix", "boards.json"))
        self.families = matrix.expand(self.data)

    def test_every_board_has_every_column(self):
        keys = [k for k, _ in self.data["columns"]]
        boards = [b for f in self.families for b in f["boards"]]
        self.assertEqual(len(boards), 42)
        self.assertEqual(len({b["id"] for b in boards}), 42)
        for b in boards:
            self.assertEqual(list(b["r"]), keys, b["id"])
            for v in b["r"].values():
                self.assertIn(v["s"], matrix.LABELS, b["id"])

    def test_kinds_and_overrides(self):
        boards = {b["id"]: b for f in self.families for b in f["boards"]}
        self.assertEqual(boards["j804"]["r"]["gpu"], {"s": "no", "n": "no device tree"})
        self.assertEqual(boards["j804"]["r"]["inst"], {"s": "no", "n": "not offered"})
        self.assertEqual(boards["j604"]["r"]["xtra"]["s"], "part")
        self.assertEqual(boards["j293"]["r"]["xtra"], {"s": "on", "n": "Touch Bar"})
        self.assertEqual(boards["j313"]["r"]["gpu"], {"s": "on"})

    def test_no_bare_unlinked_numbers(self):
        import re
        for f in self.families:
            for b in f["boards"]:
                for v in b["r"].values():
                    rest = re.sub(r"<a\s[^>]*>.*?</a>", "", v.get("n", ""))
                    self.assertNotRegex(rest, r"(?<![\w&])#\d+", b["id"])


class DtsTest(unittest.TestCase):
    def test_parent_disabled_turns_child_off(self):
        nodes = matrix.parse_dts("""/ {
	soc {
		dcp: dcp@1 {
			compatible = "apple,t8103-dcp", "apple,dcp";
		};
		bus {
			status = "disabled";
			gpu@2 {
				compatible = "apple,agx-t8103";
			};
		};
	};
};
""")
        by = {n["path"]: n for n in nodes}
        self.assertTrue(by["//soc/dcp@1"]["on"])
        self.assertFalse(by["//soc/bus/gpu@2"]["on"])
        st, _ = matrix.feature_state(nodes, r"^apple,t\d{4}-dcp$", {"apple,dcp"}, set())
        self.assertEqual(st, "driver")
        st, _ = matrix.feature_state(nodes, r"^apple,agx-", {"apple,agx-t8103"}, set())
        self.assertEqual(st, "dt-off")
        st, _ = matrix.feature_state(nodes, r"-isp$", set(), set())
        self.assertEqual(st, "absent")


class BuildTest(unittest.TestCase):
    def test_build_writes_page_basecamp_and_data(self):
        with tempfile.TemporaryDirectory() as out:
            matrix.main(["build", "--out", out, "--scan", os.path.join(ROOT, "scripts", "macbook-support-matrix", "scan.json")])
            page = read(os.path.join(out, "index.html"))
            self.assertNotIn("{{", page)
            self.assertIn("linux-aurora/commit/", page)
            bc = read(os.path.join(out, "basecamp.html"))
            self.assertIn("var(--highlight-3)", bc)
            self.assertIn("lexxy-content__table-wrapper", bc)
            data = json.loads(read(os.path.join(out, "matrix-data.json")))
            self.assertEqual(sum(len(f["boards"]) for f in data), 42)

    def test_committed_scan_agrees_with_boards(self):
        data = matrix.load_data(os.path.join(ROOT, "scripts", "macbook-support-matrix", "boards.json"))
        scan = matrix.load_data(os.path.join(ROOT, "scripts", "macbook-support-matrix", "scan.json"))
        self.assertEqual(matrix.disagreements(matrix.expand(data), scan), [])


if __name__ == "__main__":
    unittest.main()
