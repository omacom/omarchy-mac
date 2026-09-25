# The Omarchy Mac manual

End-user documentation for Omarchy on Apple Silicon Macs. It is a static site with no JavaScript framework and no Node toolchain: fourteen Markdown pages, four generated SVG diagrams and one stylesheet.

It covers only what differs on a Mac and links to [Omarchy's manual](https://omarchy.org/manual/) for everything else. Omarchy's own manual stays in `../manual/`. This tree is Mac-only, so like `packages/` and `tools/` it stays out of upstream desktop submissions.

## Build it

```bash
pip install "markdown==3.7"
python3 mac-manual/diagrams/gen.py
python3 mac-manual/build.py
python3 -m http.server 8877 --directory mac-manual/dist
```

`dist/` is not committed. `.github/workflows/mac-manual.yml` builds the site on every pull request and push that touches `mac-manual/`, fails when a diagram is out of date or a link is broken, and uploads the result as a Pages artifact. It does not deploy.

## Publishing

The manual is not published yet; where it lives is the repository owner's decision. To publish it on GitHub Pages:

1. Set Pages to deploy from GitHub Actions in the repository settings.
2. Add a `deploy` job after `build` that runs `actions/deploy-pages`, with `pages: write` and `id-token: write`, on pushes only.
3. Set `MAC_MANUAL_URL` in the build step to the published address. With it, every page carries a canonical link and the build writes `sitemap.xml`; without it, both are left out.

## Where things live

| Path | What it is |
| --- | --- |
| `content/NN-slug.md` | One page. The number orders it in the chapter rail; the slug is the URL. |
| `diagrams/gen.py` | Builds every SVG. Edit this, never the SVGs. |
| `diagrams/*.svg` | Generated and committed. CI regenerates them and fails if they differ. |
| `templates/page.html` | The page shell. |
| `assets/site.css` | The whole stylesheet. |
| `build.py` | Renders the Markdown and writes `dist/`. |

## Writing a page

Front matter sets the title, the description search engines show, and the section heading in the rail:

```markdown
---
title: Updates and channels
description: Which channel a Mac follows and what omarchy update does on a Mac.
section: Using it
---
```

A page with no `section` continues under the heading above it, so only the first page of each group needs one.

Place a diagram with `{{diagram:name}}` on its own line, where `name` matches a file in `diagrams/`. Link to another page with `[text]({{page:slug}})`, never a hand-written relative path: the index sits one directory above the rest, so a path that works on one page is wrong on the other. The builder fails on an unknown diagram or slug, and it checks every link in the finished site, so a rename cannot leave a dead link behind.

Describe what an installed Mac does, and link to Omarchy's manual for anything that is the same on every machine. Change a page in the same pull request as the behaviour it describes. Until the first release, the front page and the Status page say that the pages describe the target; remove those notes when it ships.

## Design

The manual deliberately follows <https://omarchy.org/manual/>: Geist for headings, JetBrains Mono for body text, a 48rem measure, a 16rem chapter rail, square corners and the Tokyo Night palette. Keep it that way, so a reader moving between the two manuals does not feel a seam. It is dark only, by choice.

Diagrams carry no colours of their own. They use the `.diagram` classes in the stylesheet, so they follow the palette. `gen.py` refuses to emit a diagram whose text would overflow its box or whose nodes fall off the canvas.

## Provenance

Moved from maralcbr/omarchy-mx-mac `docs/site/` at `b8ab4b7f0827f3ed840594ec6994e4295bf6f88b` (2026-09-25). The first commit touching this directory copies `build.py`, `diagrams/gen.py`, `templates/page.html` and `assets/` unchanged (they are identical at `8e70a5cd`, the revision that commit names); their earlier history is `git log b8ab4b7f -- docs/site` in omarchy-mx-mac (#215, #252).

The pages were rewritten for the converged stack: the omacom installer, official Omarchy with `omarchy-mac` and `omarchy-mac-boot` from omacom/omarchy-pkgs, the Aurora kernel only, Limine, the encryption lifecycle and the move of existing Macs. Left behind as fork-only: the fork's repositories, release lanes and download links, the per-channel Aurora kernel lanes and their repository pins, the runtime bundle and legacy repository updaters, the release pipeline, the testing and evidence page (the validation runbook and evidence move with the hardware tooling), and the generated package map. The build no longer hard-codes a domain or a download link.

The mx-mac `manual/` differs from Omarchy's only by upstream drift, a pointer to the fork's site and a Voxtype note that belongs in Omarchy's own manual, so none of it moved.
