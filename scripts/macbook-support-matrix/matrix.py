#!/usr/bin/env python3
"""Build the Apple Silicon MacBook support matrix from code evidence.

boards.json holds the curated matrix: one cell per board and feature, with
the gate or PR that decides it. The device-tree scan is the evidence behind
those cells, and is kept in scan.json so a refresh can show what changed.

  python3 matrix.py scan --kernel ~/src/linux-aurora --out scan.json
  python3 matrix.py diff --old scan.json --new /tmp/scan.json
  python3 matrix.py build --out /tmp/matrix [--scan scan.json]

scan needs a C preprocessor (cc) and dtc. diff and build are stdlib only.
"""

import argparse
import glob
import html
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GH = "https://github.com/omacom"
REPOS = ("linux-aurora", "m1n1", "mesa", "omarchy-mac", "omarchy-pkgs")
LABELS = {"on": "On", "opt": "Opt-in", "part": "Partial", "pr": "In PR", "no": "Missing", "na": "N/A"}
SOURCE_EXT = (".c", ".h", ".rs")

# Device-tree features and the compatible pattern that identifies each one.
FEATURES = [
    ("storage", r"-nvme-ans[23]$"),
    ("cpufreq", r"-cluster-cpufreq$"),
    ("kbd_tp", r"^apple,spi-hid-transport$|^apple,dockchannel-hid$"),
    ("wifi", r"^pci14e4,44|^pci14c3,7932$"),
    ("bt", r"^pci14e4,5f"),
    ("speakers", r"-macaudio$"),
    ("jack", r"^cirrus,cs42l8"),
    ("mics", r"-aop-audio$"),
    ("display", r"^apple,t\d{4}-dcp$"),
    ("gpu", r"^apple,agx-"),
    ("usb", r"-dwc3$"),
    ("tb", r"-usb4-nhi$"),
    ("extdisp", r"-dcpext$"),
    ("camera", r"-isp$"),
    ("vdec", r"-avd$"),
    ("sd", r"^pci17a0,9755$"),
    ("battery", r"-smc$"),
    ("als", r"-aop-als$"),
    ("kbdlight", r"^pwm-leds$"),
    ("touchbar", r"-touchbar$"),
    ("touchid", r"-fingerprint$"),
]

# Matrix column -> device-tree features that provide it, for build --scan.
COLUMN_FEATURES = {
    "stor": ["storage"], "kbd": ["kbd_tp"], "net": ["wifi", "bt"], "spk": ["speakers"],
    "jack": ["jack"], "disp": ["display"], "gpu": ["gpu"], "usb": ["usb"], "ext": ["extdisp"],
    "cam": ["camera"], "vdec": ["vdec"], "batt": ["battery"], "pwr": ["cpufreq"], "tid": ["touchid"],
}

LINK_RE = re.compile(r"(?<![\w&/])(?:(" + "|".join(REPOS) + r"))?#(\d+)\b")


def link(text):
    """Turn repo#N and bare #N into omacom PR links; bare #N reuses the last repo named."""
    parts = re.split(r"(<a\s[^>]*>.*?</a>)", text)
    repo = "linux-aurora"
    out = []
    for part in parts:
        if part.startswith("<a "):
            m = re.search(r"github\.com/omacom/([\w-]+)/pull/", part)
            if m:
                repo = m.group(1)
            out.append(part)
            continue

        def sub(m):
            nonlocal repo
            if m.group(1):
                repo = m.group(1)
            label = m.group(0)
            return f'<a href="{GH}/{repo}/pull/{m.group(2)}">{label}</a>'

        out.append(LINK_RE.sub(sub, part))
    return "".join(out)


def load_data(path):
    with open(path) as f:
        return json.load(f)


def cell(v):
    return {"s": v[0], "n": link(v[1])} if len(v) > 1 else {"s": v[0]}


def expand(data):
    """Expand each board's kind defaults and overrides into one cell per column."""
    keys = [k for k, _ in data["columns"]]
    families = []
    for f in data["families"]:
        boards = []
        for b in f["boards"]:
            kind = data["kinds"][b["kind"]]
            r = {k: cell(kind["fill"]) for k in keys} if "fill" in kind else {}
            r.update({k: cell(v) for k, v in kind.get("cells", {}).items()})
            r.update({k: cell(v) for k, v in b.get("cells", {}).items()})
            missing = [k for k in keys if k not in r]
            if missing:
                raise SystemExit(f"{b['id']}: no value for {', '.join(missing)}")
            boards.append({"id": b["id"], "n": b["name"], "cfg": b.get("config", ""), "kind": b["kind"],
                           "r": {k: r[k] for k in keys}, "boot_enables": b.get("boot_enables", []),
                           "tree_in_pr": b.get("tree_in_pr", "")})
        families.append({"name": f["name"], "soc": f["soc"], "note": link(f.get("note", "")), "boards": boards})
    return families


# --- scan -------------------------------------------------------------------

def parse_dts(text):
    """Return [{path, compat, on}] for every node of a dtc -O dts dump."""
    stack, nodes = [], {}
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r"^(?:[\w,-]+:\s*)*([\w,@.+-]+|/)\s*\{$", s)
        if m:
            stack.append(m.group(1))
            nodes.setdefault("/".join(stack), {"compat": [], "status": "okay"})
            continue
        if s.startswith("};"):
            stack.pop()
            continue
        if not stack:
            continue
        n = nodes["/".join(stack)]
        km = re.match(r"^([\w,#.+-]+)\s*=\s*(.*);$", s)
        if not km:
            continue
        k, v = km.groups()
        if k == "compatible":
            n["compat"] = re.findall(r'"([^"]+)"', v)
        elif k == "status":
            n["status"] = re.findall(r'"([^"]+)"', v)[0]
    out = []
    for p, n in nodes.items():
        parts = p.split("/")
        on = all(nodes.get("/".join(parts[:i]), {"status": "okay"})["status"] in ("okay", "ok")
                 for i in range(1, len(parts) + 1))
        out.append({"path": p, "compat": n["compat"], "on": on})
    return out


def compile_dts(kernel, dts):
    apple = os.path.join(kernel, "arch/arm64/boot/dts/apple")
    pre = subprocess.run(["cc", "-E", "-nostdinc", "-undef", "-D__DTS__", "-x", "assembler-with-cpp",
                          "-I", apple, "-I", os.path.join(kernel, "include"),
                          "-I", os.path.join(kernel, "scripts/dtc/include-prefixes"), dts],
                         capture_output=True, text=True, check=True).stdout
    # dtc cannot parse the floating-point cells some Apple trees carry; they are not needed here.
    pre = re.sub(r"<\s*-?\d+\.\d+[^>]*>", "<0>", pre)
    return subprocess.run(["dtc", "-q", "-I", "dts", "-O", "dts", "-o", "-", "-"],
                          input=pre, capture_output=True, text=True, check=True).stdout


def driver_strings(kernel):
    """Every string literal in drivers/ and sound/ that could be a compatible."""
    found = set()
    rx = re.compile(r'"([A-Za-z0-9][\w,.+-]{1,63})"')
    for top in ("drivers", "sound"):
        for root, _, files in os.walk(os.path.join(kernel, top)):
            for name in files:
                if name.endswith(SOURCE_EXT):
                    with open(os.path.join(root, name), errors="replace") as f:
                        found.update(rx.findall(f.read()))
    return found


def feature_state(nodes, rx, drivers, pci_ids):
    hit = [n for n in nodes if any(re.search(rx, c) for c in n["compat"])]
    if not hit:
        return "absent", []
    on = [n for n in hit if n["on"]]
    if not on:
        return "dt-off", hit
    ok = [n for n in on if any(c in drivers or c in pci_ids for c in n["compat"])]
    return ("driver" if ok else "no-driver"), on


def git_head(kernel):
    r = subprocess.run(["git", "-C", kernel, "rev-parse", "HEAD"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def cmd_scan(args):
    data = load_data(args.data)
    apple = os.path.join(args.kernel, "arch/arm64/boot/dts/apple")
    if not os.path.isdir(apple):
        raise SystemExit(f"{apple}: not a linux-aurora tree")
    drivers = driver_strings(args.kernel)
    pci_ids = set(data["pci_ids_with_driver"])
    boards = {}
    for f in data["families"]:
        for b in f["boards"]:
            trees = sorted(glob.glob(os.path.join(apple, f"t*-{b['id']}.dts")))
            if not trees:
                boards[b["id"]] = {"tree": None}
                continue
            nodes = parse_dts(compile_dts(args.kernel, trees[0]))
            feats = {}
            for name, rx in FEATURES:
                st, hit = feature_state(nodes, rx, drivers, pci_ids)
                feats[name] = {"state": st, "compat": sorted({n["compat"][0] for n in hit})[:3]}
            boards[b["id"]] = {"tree": os.path.basename(trees[0]), "features": feats}
    out = {"kernel": git_head(args.kernel), "boards": boards}
    with open(args.out, "w") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")
    print(f"{len(boards)} boards, {sum(1 for b in boards.values() if b['tree'])} with a device tree -> {args.out}")


# --- diff -------------------------------------------------------------------

def cmd_diff(args):
    old, new = load_data(args.old), load_data(args.new)
    print(f"kernel {old.get('kernel', '?')[:12]} -> {new.get('kernel', '?')[:12]}")
    changes = 0
    for bid in sorted(set(old["boards"]) | set(new["boards"])):
        a, b = old["boards"].get(bid, {"tree": None}), new["boards"].get(bid, {"tree": None})
        if a.get("tree") != b.get("tree"):
            print(f"{bid}: device tree {a.get('tree')} -> {b.get('tree')}")
            changes += 1
        fa, fb = a.get("features", {}), b.get("features", {})
        for name in sorted(set(fa) | set(fb)):
            sa, sb = fa.get(name, {}).get("state", "-"), fb.get(name, {}).get("state", "-")
            if sa != sb:
                print(f"{bid}: {name} {sa} -> {sb}")
                changes += 1
    print(f"{changes} change(s); update boards.json cells for each one that matters")


# --- build ------------------------------------------------------------------

def snapshot_line(snap):
    la, m1 = snap["linux-aurora"], snap["m1n1"]
    return (f'linux-aurora <a href="{GH}/linux-aurora/commit/{la["sha"]}">{la["sha"][:12]}</a> ({la["date"]}) · '
            f'm1n1 <a href="{GH}/m1n1/commit/{m1["sha"]}">{m1["sha"][:7]}</a> ({m1["date"]}) · {snap["catalog"]}')


def page(data, families):
    with open(os.path.join(HERE, "page.html")) as f:
        tpl = f.read()
    blob = json.dumps({"columns": data["columns"], "families": families}, ensure_ascii=False)
    return tpl.replace("{{SNAPSHOT}}", snapshot_line(data["snapshot"])).replace("{{DATA}}", blob.replace("</", "<\\/"))


def bc_p(x):
    return f'<p dir="auto">{x}</p>'


def bc_red(x):
    return f'<mark style="color: var(--highlight-3);">{x}</mark>'


def bc_cell(v):
    s = f"<strong>{LABELS[v['s']]}</strong>" + (f". {v['n']}" if v.get("n") else "")
    return bc_red(s) if v["s"] == "no" else s


def bc_table(head, rows):
    h = "<tr>\n" + "".join(f"<th><p>{x}</p></th>\n" for x in head) + "</tr>\n"
    b = "".join("<tr>\n" + "".join(f"<td><p>{x}</p></td>\n" for x in r) + "</tr>\n" for r in rows)
    return f'<figure class="lexxy-content__table-wrapper" dir="auto"><table><tbody>\n{h}{b}</tbody></table></figure>'


def basecamp(data, families):
    """Basecamp (Lexxy) document HTML: Missing cells in red, boards without a tree in their own table."""
    bc = data["basecamp"]
    titles = {**dict(data["columns"]), **bc.get("titles", {})}
    main = ["inst", "disp", "gpu", "ext", "pwr", "tid", "xtra"]
    common = [k for k, _ in data["columns"] if k not in main]
    snap = data["snapshot"]
    la, m1 = snap["linux-aurora"], snap["m1n1"]
    out = [bc_p(link(x)) for x in bc["intro"]]
    out.append(bc_p(f'Snapshot: linux-aurora <a href="{GH}/linux-aurora/commit/{la["sha"]}">{la["sha"][:12]}</a> and m1n1 '
                    f'<a href="{GH}/m1n1/commit/{m1["sha"]}">{m1["sha"][:7]}</a>, {snap["basecamp_date"]}. Installer catalog: {snap["catalog"].replace("edge catalog", "edge,")}.'))
    out.append(bc_p("<br>"))
    out.append('<h2 dir="auto">Summary</h2>')
    out.append('<ul dir="auto">' + "".join(f"<li><p>{link(x)}</p></li>" for x in bc["summary"]) + "</ul>")
    out.append(bc_p("<br>"))
    out.append('<h2 dir="auto">Status labels</h2>')
    out.append('<ul dir="auto">' + "".join(
        f"<li><p>{bc_red(f'<strong>{LABELS[k]}:</strong> {t} Shown in red.') if k == 'no' else f'<strong>{LABELS[k]}:</strong> {t}'}</p></li>"
        for k, t in bc["labels"]) + "</ul>")
    out.append(bc_p("<br>"))
    out.append('<h2 dir="auto">Support by board</h2>')
    out.append(bc_p(bc["common_note"]))
    for f in families:
        out.append(f'<h3 dir="auto">{f["name"]} ({f["soc"]})</h3>')
        if f["note"]:
            out.append(bc_p(f["note"]))
        rows = [b for b in f["boards"] if b["kind"] != "no-tree"]
        if rows:
            out.append(bc_table(["Board"] + [titles[k] for k in main] + ["Common hardware"], [
                [f"{b['n']}<br><code>{b['id'].upper()}</code>" + (f" · {b['cfg']}" if b["cfg"] else "")]
                + [bc_cell(b["r"][k]) for k in main]
                + ["<br>".join(f"{titles[k]}: {bc_cell(b['r'][k])}" for k in common if b["r"][k]["s"] != "on") or "All on"]
                for b in rows]))
        nodt = [b for b in f["boards"] if b["kind"] == "no-tree"]
        if nodt:
            out.append(bc_table(["Board", "Released", "State"], [
                [bc_red(b["n"]) + f"<br><code>{b['id'].upper()}</code>", bc_red(b["cfg"]),
                 bc_red("<strong>Missing.</strong> No device tree; not in the catalog.")] for b in nodt]))
    out.append(bc_p("<br>"))
    out.append('<h2 dir="auto">Evidence</h2>')
    out.append('<ul dir="auto">' + "".join(f"<li><p>{link(x)}</p></li>" for x in bc["evidence"]) + "</ul>")
    return "".join(out)


def disagreements(families, scan):
    """Cells the curated data and the device-tree scan disagree on."""
    out = []
    for f in families:
        for b in f["boards"]:
            s = scan["boards"].get(b["id"], {"tree": None})
            if b["tree_in_pr"] and s.get("tree") is None:
                continue
            if (b["kind"] == "no-tree") != (s.get("tree") is None):
                out.append(f"{b['id']}: kind {b['kind']} but scan tree is {s.get('tree')}")
                continue
            if not s.get("tree"):
                continue
            for col, feats in COLUMN_FEATURES.items():
                states = {s["features"][x]["state"] for x in feats}
                v = b["r"][col]
                if col in b["boot_enables"] and "dt-off" in states:
                    continue
                if v["s"] == "on" and "driver" not in states:
                    out.append(f"{b['id']}: {col} is On but the scan finds {'/'.join(sorted(states))}")
                elif v["s"] == "no" and v.get("n") == "not described" and "absent" not in states:
                    out.append(f"{b['id']}: {col} says not described but the scan finds {'/'.join(sorted(states))}")
    return out


def cmd_build(args):
    data = load_data(args.data)
    families = expand(data)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "index.html"), "w") as f:
        f.write(page(data, families))
    with open(os.path.join(args.out, "basecamp.html"), "w") as f:
        f.write(basecamp(data, families))
    with open(os.path.join(args.out, "matrix-data.json"), "w") as f:
        json.dump([{**f, "boards": [{k: b[k] for k in ("id", "n", "cfg", "r")} for b in f["boards"]]} for f in families],
                  f, indent=1, ensure_ascii=False)
        f.write("\n")
    count = sum(len(f["boards"]) for f in families)
    print(f"{count} boards -> {args.out}/index.html, basecamp.html, matrix-data.json")
    if args.scan:
        found = disagreements(families, load_data(args.scan))
        for line in found:
            print("check:", line)
        print(f"{len(found)} cell(s) disagree with the scan; each needs a gate or note in boards.json, or a fix")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan", help="compile every MacBook device tree and record which features bind a driver")
    s.add_argument("--kernel", required=True, help="linux-aurora checkout")
    s.add_argument("--data", default=os.path.join(HERE, "boards.json"))
    s.add_argument("--out", required=True)
    d = sub.add_parser("diff", help="compare two scans")
    d.add_argument("--old", default=os.path.join(HERE, "scan.json"))
    d.add_argument("--new", required=True)
    b = sub.add_parser("build", help="write the page, the Basecamp document and matrix-data.json")
    b.add_argument("--data", default=os.path.join(HERE, "boards.json"))
    b.add_argument("--out", required=True)
    b.add_argument("--scan", help="also list cells that disagree with this scan")
    args = ap.parse_args(argv)
    {"scan": cmd_scan, "diff": cmd_diff, "build": cmd_build}[args.cmd](args)


if __name__ == "__main__":
    main()
