#!/usr/bin/env python3
"""Build the Omarchy MX Mac documentation site into docs/site/dist.

Content lives in content/*.md (front matter between --- lines). Diagrams are
SVG files in diagrams/ pulled in with {{diagram:name}}. Only the `markdown`
package is required beyond the standard library.
"""

from __future__ import annotations

import html
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "content"
DIAGRAMS = ROOT / "diagrams"
ASSETS = ROOT / "assets"
TEMPLATE = ROOT / "templates" / "page.html"
DIST = ROOT / "dist"

SITE_TITLE = "Omarchy MX Mac"
SITE_URL = "https://omarchy-mx-mac.org"
REPO_URL = "https://github.com/maralcbr/omarchy-mx-mac"
DOWNLOAD_URL = (
    "https://downloads.aicodelabs.com.au/installer/stable/Omarchy-MX-Mac-Installer.pkg"
)


@dataclass
class Page:
    slug: str
    title: str
    description: str
    order: int
    body_md: str
    section: str = ""
    html: str = ""
    headings: list[tuple[str, str]] = field(default_factory=list)

    @property
    def href(self) -> str:
        return "./" if self.slug == "index" else f"./{self.slug}/"

    @property
    def out_path(self) -> Path:
        return DIST / "index.html" if self.slug == "index" else DIST / self.slug / "index.html"

    @property
    def rel_root(self) -> str:
        return "./" if self.slug == "index" else "../"


FRONT_MATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
DIAGRAM_TAG = re.compile(r"\{\{diagram:([a-z0-9-]+)\}\}")
PAGE_TAG = re.compile(r"\{\{page:([a-z0-9-]+)\}\}")
HEADING = re.compile(r'<h2 id="([^"]+)">(.*?)</h2>')


def parse_front_matter(text: str) -> tuple[dict[str, str], str]:
    m = FRONT_MATTER.match(text)
    if not m:
        raise SystemExit("missing front matter")
    meta: dict[str, str] = {}
    for line in m.group(1).splitlines():
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip().strip('"')
    return meta, text[m.end() :]


def load_pages() -> list[Page]:
    pages = []
    for path in sorted(CONTENT.glob("*.md")):
        meta, body = parse_front_matter(path.read_text())
        slug = re.sub(r"^\d+-", "", path.stem)
        pages.append(
            Page(
                slug=slug,
                title=meta["title"],
                description=meta.get("description", ""),
                order=int(meta.get("order", path.stem.split("-")[0])),
                section=meta.get("section", ""),
                body_md=body,
            )
        )
    pages.sort(key=lambda p: p.order)
    return pages


def inline_diagram(match: re.Match[str]) -> str:
    name = match.group(1)
    svg_path = DIAGRAMS / f"{name}.svg"
    if not svg_path.exists():
        raise SystemExit(f"diagram not found: {svg_path}")
    svg = svg_path.read_text().strip()
    return f'<figure class="diagram" data-diagram="{name}">\n{svg}\n</figure>'


def resolve_page_links(body: str, current: Page, slugs: set[str]) -> str:
    """Turn {{page:slug}} into a link that works from this page's directory.

    Pages live one directory deep except the index, so a hand-written relative
    link is right on one page and wrong on the other. The slug is checked here,
    which makes a typo or a renamed page a build failure rather than a 404."""

    def one(m: re.Match[str]) -> str:
        slug = m.group(1)
        if slug not in slugs:
            raise SystemExit(f"{current.slug}: link to unknown page {slug!r}")
        return current.rel_root + ("" if slug == "index" else f"{slug}/")

    return PAGE_TAG.sub(one, body)


def render_markdown(body: str) -> str:
    body = DIAGRAM_TAG.sub(inline_diagram, body)
    md = markdown.Markdown(
        extensions=["fenced_code", "tables", "toc", "attr_list", "md_in_html"],
        extension_configs={"toc": {"permalink": False, "toc_depth": "2-3"}},
    )
    return md.convert(body)


def add_heading_links(rendered: str) -> str:
    def link(m: re.Match[str]) -> str:
        anchor, text = m.group(1), m.group(2)
        return (
            f'<h2 id="{anchor}"><a class="heading-link" href="#{anchor}">{text}'
            f'<span class="hash" aria-hidden="true">#</span></a></h2>'
        )

    return HEADING.sub(link, rendered)


def nav_list(pages: list[Page], current: Page) -> str:
    items = []
    section = None
    for p in pages:
        if p.section and p.section != section:
            section = p.section
            items.append(f'<li class="rail-section">{html.escape(section)}</li>')
        cls = ' class="active" aria-current="page"' if p is current else ""
        href = current.rel_root + ("" if p.slug == "index" else f"{p.slug}/")
        items.append(f'<li><a{cls} href="{href}" title="{html.escape(p.title)}">{html.escape(p.title)}</a></li>')
    return "\n".join(items)


def pager(pages: list[Page], current: Page) -> str:
    i = pages.index(current)
    prev = pages[i - 1] if i > 0 else None
    nxt = pages[i + 1] if i + 1 < len(pages) else None

    def link(p: Page | None, cls: str, arrow_before: bool) -> str:
        if p is None:
            return "<span></span>"
        href = current.rel_root + ("" if p.slug == "index" else f"{p.slug}/")
        arrow = '<span aria-hidden="true">&larr;</span> ' if arrow_before else ' <span aria-hidden="true">&rarr;</span>'
        text = html.escape(p.title)
        inner = f"{arrow}{text}" if arrow_before else f"{text}{arrow}"
        return f'<a class="{cls}" href="{href}">{inner}</a>'

    return link(prev, "pager-prev", True) + link(nxt, "pager-next", False)


def build() -> None:
    pages = load_pages()
    slugs = {p.slug for p in pages}
    template = TEMPLATE.read_text()
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir()
    shutil.copytree(ASSETS, DIST / "assets")
    (DIST / ".nojekyll").write_text("")

    for page in pages:
        page.html = add_heading_links(render_markdown(resolve_page_links(page.body_md, page, slugs)))
        page.headings = re.findall(r'<h2 id="([^"]+)"><a[^>]*>(.*?)<span', page.html)
        canonical = SITE_URL + "/" + ("" if page.slug == "index" else f"{page.slug}/")
        title = SITE_TITLE if page.slug == "index" else f"{page.title} - {SITE_TITLE}"
        out = template
        for key, value in {
            "{{title}}": html.escape(title),
            "{{page_title}}": html.escape(page.title),
            "{{description}}": html.escape(page.description),
            "{{canonical}}": canonical,
            "{{root}}": page.rel_root,
            "{{nav}}": nav_list(pages, page),
            "{{content}}": page.html,
            "{{pager}}": pager(pages, page),
            "{{repo_url}}": REPO_URL,
            "{{download_url}}": DOWNLOAD_URL,
        }.items():
            out = out.replace(key, value)
        leftovers = re.findall(r"\{\{[a-z_]+\}\}", out)
        if leftovers:
            raise SystemExit(f"unreplaced template tokens in {page.slug}: {leftovers}")
        page.out_path.parent.mkdir(parents=True, exist_ok=True)
        page.out_path.write_text(out)

    sitemap = "\n".join(
        f"  <url><loc>{SITE_URL}/{'' if p.slug == 'index' else p.slug + '/'}</loc></url>" for p in pages
    )
    (DIST / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f"{sitemap}\n</urlset>\n"
    )
    check_links()
    print(f"built {len(pages)} pages into {DIST.relative_to(ROOT.parent.parent)}")


def check_links() -> None:
    """Every local href and src in the output must resolve to a real file."""
    broken = []
    for page in DIST.rglob("index.html"):
        html_text = page.read_text()
        for ref in re.findall(r'(?:href|src)="([^"]+)"', html_text):
            if ref.startswith(("http://", "https://", "#", "mailto:", "data:")):
                continue
            target = (page.parent / ref.split("#")[0]).resolve()
            if target.is_dir():
                target = target / "index.html"
            if not target.exists():
                broken.append(f"{page.relative_to(DIST)} -> {ref}")
    if broken:
        raise SystemExit("broken links:\n  " + "\n  ".join(broken))


if __name__ == "__main__":
    try:
        build()
    except SystemExit as e:
        print(e, file=sys.stderr)
        raise
