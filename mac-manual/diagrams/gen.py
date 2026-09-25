#!/usr/bin/env python3
"""Generate the manual's architecture diagrams as SVG.

Each diagram is a list of lanes, nodes and edges placed on a fixed grid. The
SVGs carry no colours of their own: the page stylesheet themes them through the
.diagram classes, so they follow the site theme like everything else.
Run it after editing and commit the SVGs; the mac-manual workflow checks they match.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).resolve().parent


@dataclass
class Node:
    id: str
    x: int
    y: int
    title: str
    sub: list[str] = field(default_factory=list)
    w: int = 220
    h: int = 0
    tone: str = ""

    def __post_init__(self) -> None:
        if not self.h:
            self.h = 34 + 17 * len(self.sub) + (6 if self.sub else 0)

    @property
    def cx(self) -> float:
        return self.x + self.w / 2

    @property
    def cy(self) -> float:
        return self.y + self.h / 2

    def port(self, side: str) -> tuple[float, float]:
        return {
            "top": (self.cx, self.y),
            "bottom": (self.cx, self.y + self.h),
            "left": (self.x, self.cy),
            "right": (self.x + self.w, self.cy),
        }[side]


@dataclass
class Lane:
    x: int
    y: int
    w: int
    h: int
    title: str
    sub: str = ""


@dataclass
class Edge:
    src: str
    dst: str
    label: str = ""
    src_side: str = ""
    dst_side: str = ""
    cls: str = ""


@dataclass
class Diagram:
    name: str
    width: int
    height: int
    label: str
    lanes: list[Lane] = field(default_factory=list)
    nodes: list[Node] = field(default_factory=list)
    edges: list[Edge] = field(default_factory=list)
    legend: list[tuple[str, str]] = field(default_factory=list)

    def node(self, id: str) -> Node:
        return next(n for n in self.nodes if n.id == id)

    def check(self) -> None:
        """Refuse to emit a diagram whose text would spill out of its box.

        JetBrains Mono is 0.6em wide per character; the CSS sizes titles at
        13.5px and subtitles at 11.5px inside a 12px padding on each side."""
        for n in self.nodes:
            room = n.w - 24
            if len(n.title) * 13.5 * 0.6 > room:
                raise SystemExit(f"{self.name}: title too wide for {n.id}: {n.title!r}")
            for line in n.sub:
                if len(line) * 11.5 * 0.6 > room:
                    raise SystemExit(f"{self.name}: sub line too wide for {n.id}: {line!r}")
            if n.x + n.w > self.width or n.y + n.h > self.height:
                raise SystemExit(f"{self.name}: node {n.id} falls outside the canvas")
        for lane in self.lanes:
            room = lane.w - 28
            if len(lane.sub) * 11.5 * 0.6 > room:
                raise SystemExit(f"{self.name}: lane sub too wide: {lane.sub!r}")
        for n in self.nodes:
            lane = next(
                (
                    l
                    for l in self.lanes
                    if l.x <= n.x and n.x + n.w <= l.x + l.w + 1 and l.y <= n.y < l.y + l.h
                ),
                None,
            )
            if lane and n.y + n.h > lane.y + lane.h:
                raise SystemExit(f"{self.name}: node {n.id} overflows the bottom of its lane")
        for i, a in enumerate(self.nodes):
            for b in self.nodes[i + 1 :]:
                if (
                    a.x < b.x + b.w
                    and b.x < a.x + a.w
                    and a.y < b.y + b.h
                    and b.y < a.y + a.h
                ):
                    raise SystemExit(f"{self.name}: nodes {a.id} and {b.id} overlap")

    def render(self) -> str:
        self.check()
        out = [
            f'<svg viewBox="0 0 {self.width} {self.height}" role="img" aria-label="{escape(self.label)}" xmlns="http://www.w3.org/2000/svg">',
            "<defs>"
            '<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" class="arrow"/></marker>'
            '<marker id="arrow-brand" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" class="arrow brand"/></marker>'
            "</defs>",
        ]
        for lane in self.lanes:
            out.append(f'<rect class="lane" x="{lane.x}" y="{lane.y}" width="{lane.w}" height="{lane.h}"/>')
            out.append(f'<text class="lane-title" x="{lane.x + 14}" y="{lane.y + 24}">{escape(lane.title)}</text>')
            if lane.sub:
                out.append(f'<text class="lane-sub" x="{lane.x + 14}" y="{lane.y + 42}">{escape(lane.sub)}</text>')
        for e in self.edges:
            a, b = self.node(e.src), self.node(e.dst)
            src_side, dst_side = e.src_side, e.dst_side
            if not src_side or not dst_side:
                if abs(a.cx - b.cx) < 8 or abs(a.cy - b.cy) > abs(a.cx - b.cx):
                    src_side = src_side or ("bottom" if b.cy > a.cy else "top")
                    dst_side = dst_side or ("top" if b.cy > a.cy else "bottom")
                else:
                    src_side = src_side or ("right" if b.cx > a.cx else "left")
                    dst_side = dst_side or ("left" if b.cx > a.cx else "right")
            x1, y1 = a.port(src_side)
            x2, y2 = b.port(dst_side)
            if src_side in ("top", "bottom") and dst_side in ("top", "bottom"):
                my = (y1 + y2) / 2
                d = f"M {x1} {y1} C {x1} {my} {x2} {my} {x2} {y2}"
            elif src_side in ("left", "right") and dst_side in ("left", "right"):
                mx = (x1 + x2) / 2
                d = f"M {x1} {y1} C {mx} {y1} {mx} {y2} {x2} {y2}"
            elif src_side in ("left", "right"):
                d = f"M {x1} {y1} C {x2} {y1} {x2} {y1} {x2} {y2}"
            else:
                d = f"M {x1} {y1} C {x1} {y2} {x1} {y2} {x2} {y2}"
            marker = "arrow-brand" if "brand" in e.cls else "arrow"
            cls = f"edge {e.cls}".strip()
            out.append(f'<path class="{cls}" d="{d}" marker-end="url(#{marker})"/>')
            if e.label:
                lx, ly = (x1 + x2) / 2, (y1 + y2) / 2 - 4
                out.append(f'<text class="edge-label" x="{lx:.0f}" y="{ly:.0f}">{escape(e.label)}</text>')
        for n in self.nodes:
            cls = f"node {n.tone}".strip()
            out.append(f'<g class="{cls}">')
            out.append(f'<rect x="{n.x}" y="{n.y}" width="{n.w}" height="{n.h}"/>')
            out.append(f'<text class="n-title" x="{n.x + 12}" y="{n.y + 21}">{escape(n.title)}</text>')
            for i, s in enumerate(n.sub):
                out.append(f'<text class="n-sub" x="{n.x + 12}" y="{n.y + 40 + 17 * i}">{escape(s)}</text>')
            out.append("</g>")
        if self.legend:
            x = 16
            y = self.height - 14
            for tone, text in self.legend:
                out.append(f'<g class="node {tone}"><rect x="{x}" y="{y - 11}" width="14" height="14"/></g>')
                out.append(f'<text class="legend" x="{x + 20}" y="{y}">{escape(text)}</text>')
                x += 20 + 7.5 * len(text) + 28
        out.append("</svg>")
        return "\n".join(out) + "\n"


def repos() -> Diagram:
    d = Diagram("repositories", 900, 620, "How the Mac packages, the package repository and the installer fit together")
    d.lanes = [
        Lane(16, 16, 276, 370, "omacom/omarchy-mac", "Mac packages and tooling"),
        Lane(312, 16, 276, 370, "omacom/omarchy-pkgs", "the signed package repository"),
        Lane(608, 16, 276, 370, "omacom/omarchy-mac-installer", "the macOS app and the image"),
    ]
    W = 236
    d.nodes = [
        Node("mac-pkg", 36, 70, "omarchy-mac", ["microphone, Wi-Fi resume,", "notch, Wi-Fi backend"], w=W),
        Node("boot-pkg", 36, 170, "omarchy-mac-boot", ["initramfs, encryption,", "first boot, Limine"], w=W),
        Node("tools", 36, 270, "Mac tooling", ["release, VM and hardware", "acceptance"], w=W),
        Node("recipes", 332, 70, "Recipes", ["commit-pinned sources:", "omarchy, omarchy-mac,", "linux-aurora, m1n1, U-Boot"], w=W),
        Node("build", 332, 190, "Signed builds", ["aarch64 only, edge first,", "rc and stable once qualified"], w=W),
        Node("repo", 332, 290, "[omarchy] for aarch64", ["pkgs.omarchy.org, signed", "with the Omarchy key"], w=W, tone="tone-blue"),
        Node("image", 628, 70, "Mac image", ["signed packages pinned", "to one commit"], w=W, tone="tone-blue"),
        Node("app", 628, 190, "Installer app", ["notarized .pkg, signed", "channel catalogs"], w=W, tone="tone-brand"),
        Node("mac", 628, 290, "Your Mac", ["installs, first boot,", "then omarchy update"], w=W),
        Node("omarchy", 36, 410, "omacom/omarchy", ["the desktop: omarchy,", "omarchy-settings"], w=W, tone="tone-ext"),
        Node("upstreams", 36, 510, "Aurora and Asahi", ["aurora-silicon/linux, m1n1,", "U-Boot, installer engine"], w=W, tone="tone-ext"),
        Node("alarm", 628, 410, "Arch Linux ARM", ["core, extra, alarm and", "asahi-alarm mirrors"], w=W, tone="tone-ext"),
    ]
    d.edges = [
        Edge("mac-pkg", "recipes", src_side="right", dst_side="left"),
        Edge("boot-pkg", "recipes", src_side="right", dst_side="left"),
        Edge("omarchy", "recipes", src_side="right", dst_side="left"),
        Edge("upstreams", "recipes", src_side="right", dst_side="left"),
        Edge("recipes", "build"),
        Edge("build", "repo"),
        Edge("repo", "image", src_side="right", dst_side="left"),
        Edge("image", "app"),
        Edge("app", "mac", cls="brand"),
        Edge("repo", "mac", "", "right", "left"),
        Edge("alarm", "mac", src_side="top", dst_side="bottom"),
    ]
    d.legend = [("tone-brand", "signed installer artefact"), ("tone-blue", "signed packages or image"), ("tone-ext", "external source")]
    return d


def install_flow() -> Diagram:
    d = Diagram("install-flow", 900, 420, "What happens between clicking Install and the first desktop")
    W = 196
    d.nodes = [
        Node("app", 20, 40, "Installer app", ["Gatekeeper, channels,", "bundled trust root"], w=W, tone="tone-brand"),
        Node("catalog", 246, 40, "Signed catalog", ["Ed25519 envelope,", "sequence cannot go back"], w=W, tone="tone-brand"),
        Node("engine", 472, 40, "Pinned Asahi engine", ["APFS stub, ESP, boot", "and root partitions"], w=W),
        Node("image", 698, 40, "Image written", ["root.img, boot.img,", "m1n1, device trees"], w=W, tone="tone-blue"),
        Node("stage2", 698, 240, "recoveryOS handoff", ["the user sets the boot", "policy, one reboot"], w=W, tone="tone-ext"),
        Node("firstboot", 472, 240, "omarchy-mac-boot", ["vendor firmware, HID,", "optional LUKS"], w=W, tone="tone-blue"),
        Node("provision", 246, 240, "Owner provisioning", ["user, password, re-key,", "recovery passphrase"], w=W),
        Node("desktop", 20, 240, "Omarchy desktop", ["Hyprland + Quickshell,", "omarchy update onward"], w=W, tone="tone-brand"),
    ]
    d.edges = [
        Edge("app", "catalog", cls="brand"),
        Edge("catalog", "engine"),
        Edge("engine", "image"),
        Edge("image", "stage2", "then the user reboots", "bottom", "top"),
        Edge("stage2", "firstboot"),
        Edge("firstboot", "provision"),
        Edge("provision", "desktop", cls="brand"),
    ]
    d.legend = [("tone-brand", "signed artefact or user-facing step"), ("tone-blue", "package or image"), ("tone-ext", "Apple firmware step")]
    return d


def boot_chain() -> Diagram:
    d = Diagram("boot-chain", 900, 330, "Boot chain from Apple firmware to the Omarchy root file system")
    d.nodes = [
        Node("iboot", 20, 40, "iBoot", ["Apple firmware,", "boot policy"], w=150, tone="tone-ext"),
        Node("m1n1", 200, 40, "m1n1", ["stage 1 + 2,", "m1n1-aurora"], w=150, tone="tone-blue"),
        Node("uboot", 380, 40, "U-Boot", ["the UEFI on Apple", "Silicon, uboot-asahi"], w=220, tone="tone-blue"),
        Node("loader", 630, 40, "Limine", ["on the ESP, one entry", "per kernel and snapshot"], w=250, tone="tone-blue"),
        Node("kernel", 630, 190, "Kernel + initramfs", ["linux-aurora, mkinitcpio,", "omarchy-mac-boot hooks"], w=250, tone="tone-blue"),
        Node("root", 20, 190, "btrfs root", ["@ subvolume, snapper snapshots, optional LUKS (sd-encrypt)"], w=580),
    ]
    d.edges = [
        Edge("iboot", "m1n1"),
        Edge("m1n1", "uboot"),
        Edge("uboot", "loader"),
        Edge("loader", "kernel"),
        Edge("kernel", "root", "", "left", "right"),
    ]
    d.legend = [("tone-ext", "Apple firmware"), ("tone-blue", "signed package from omacom/omarchy-pkgs")]
    return d


def trust_chain() -> Diagram:
    d = Diagram("trust-chain", 900, 520, "What signs each artefact, and what checks the signature")
    d.lanes = [
        Lane(16, 16, 420, 460, "Signed by", "keys held by the project and its maintainers"),
        Lane(456, 16, 428, 460, "Checked by", "on the user's Mac, before anything is trusted"),
    ]
    W = 380
    d.nodes = [
        Node("apple", 36, 70, "Apple Developer ID", ["notarized installer .pkg and app"], w=W, tone="tone-brand"),
        Node("gk", 476, 70, "Gatekeeper", ["macOS refuses an unsigned or", "un-notarized installer"], w=W),
        Node("ed", 36, 170, "Ed25519 catalog key", ["held in a maintainer's Keychain,", "signs each channel catalog"], w=W, tone="tone-brand"),
        Node("root", 476, 170, "Trust root in the app bundle", ["catalog signature, and a sequence", "that may not go backwards"], w=W),
        Node("hash", 36, 290, "Per-file SHA-256 in the catalog", ["image parts, engine overlay"], w=W, tone="tone-blue"),
        Node("dl", 476, 290, "The installer app", ["hashes every file it downloads,", "reuses a cached file only on a match"], w=W),
        Node("pac", 36, 390, "Omarchy package signing key", ["every package in [omarchy],", "the Mac packages included"], w=W, tone="tone-blue"),
        Node("pm", 476, 390, "pacman and omarchy-keyring", ["SigLevel Required: refuses", "an unsigned package"], w=W),
    ]
    d.edges = [
        Edge("apple", "gk", "", "right", "left", cls="brand"),
        Edge("ed", "root", "", "right", "left", cls="brand"),
        Edge("hash", "dl", "", "right", "left"),
        Edge("pac", "pm", "", "right", "left"),
    ]
    d.legend = [("tone-brand", "maintainer or Apple key"), ("tone-blue", "project key or digest")]
    return d


def main() -> None:
    for build in (repos, install_flow, boot_chain, trust_chain):
        d = build()
        (OUT / f"{d.name}.svg").write_text(d.render())
        print(f"wrote {d.name}.svg")


if __name__ == "__main__":
    main()
