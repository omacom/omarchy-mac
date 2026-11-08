# MacBook support matrix

Read this before refreshing the Apple Silicon MacBook support matrix, or when a kernel or m1n1 change moves what a MacBook model supports.

The matrix lists every Apple Silicon MacBook (42 boards, M1 to M6 and MacBook Neo) against 16 features, and says for each cell whether linux-aurora and m1n1 drive it today. It is published as the Basecamp document [Omarchy M+ — MacBook support matrix](https://app.basecamp.com/5994298/buckets/48646031/documents/10487174851) and as a standalone HTML page.

## Files

Everything lives in `scripts/macbook-support-matrix/`:

- `boards.json` is the curated matrix and the source of truth. Each board has a `kind` (`base` for a full device tree, `stub` for a tree that describes CPUs and little else, `no-tree`) whose defaults fill every column, and `cells` that override them with the gate, PR or lab result that decides the cell. Notes are HTML; `linux-aurora#123`, `m1n1#31` or `mesa#33` become PR links, and a bare `#123` links to the last repository named in the same note (linux-aurora if none).
- `scan.json` is the device-tree evidence from the last refresh: for each board, its tree and the state of each feature (`driver`, `dt-off`, `no-driver`, `absent`).
- `page.html` is the page template. `matrix.py` fills in the snapshot line and the data.
- `matrix.py` is the stdlib-only CLI that scans, diffs and builds.

## How a cell is decided

`matrix.py scan` preprocesses and compiles every MacBook `.dts` in `arch/arm64/boot/dts/apple/`, reads each node's effective status (a node is off if it or a parent is disabled), and matches each enabled node's `compatible` strings against the string literals in `drivers/` and `sound/`. PCI devices match through `pci_ids_with_driver` in `boards.json`.

Per-board gates then decide the cell: GPU admission tables, the display board table, the speaker table, the SEP profile table, and m1n1's defaults and handoffs. Those are code, but they are not in the device tree, so they are recorded by hand in `boards.json` with the file and line that holds them. `boot_enables` lists the columns m1n1 turns on at boot for nodes the tree ships disabled. `tree_in_pr` marks a board whose tree only exists in an open PR.

## Refresh for a release candidate

1. Check out linux-aurora at the release-candidate commit. A blobless sparse checkout of `arch/arm64/boot/dts/apple/`, `include/dt-bindings/`, `scripts/dtc/include-prefixes/`, `drivers/` and `sound/` is enough. `scan` needs `cc` and `dtc`.
2. Scan it and compare with the last refresh:

   ```bash
   python3 scripts/macbook-support-matrix/matrix.py scan --kernel ~/src/linux-aurora --out /tmp/scan.json
   python3 scripts/macbook-support-matrix/matrix.py diff --new /tmp/scan.json
   ```

3. For every change the diff lists, and for every merged PR named in a cell, update the cell in `boards.json`. Re-read the gates the evidence notes cite (line numbers move), check m1n1 at the same release for default and handoff changes, and update `snapshot`.
4. Build and check the curated data against the new scan. Every line the check prints needs a gate, a `boot_enables` entry or a fix in `boards.json`:

   ```bash
   python3 scripts/macbook-support-matrix/matrix.py build --out /tmp/matrix --scan /tmp/scan.json
   ```

5. Copy `/tmp/scan.json` over `scripts/macbook-support-matrix/scan.json` and commit it with `boards.json` in one commit.
6. Publish `/tmp/matrix/basecamp.html` as the new body of the Basecamp document, and `/tmp/matrix/index.html` wherever the page is shared:

   ```bash
   basecamp files update 10487174851 --type document --in 48646031 --content - < /tmp/matrix/basecamp.html
   ```

## Rules

- A cell says what the code does, never what was hoped. On means the code is present and enabled by default; it does not mean the feature passed hardware testing. Test results live in the omarchy-m-testing.org reports and the Basecamp testing doc.
- Lab results go in the cell after the code evidence, labelled `Lab:`, with their date and source in the Power + sleep evidence.
- Add a board when Apple ships a model: take the board code and chip ID from Apple's identification pages and AppleDB, and add it as `no-tree` until a device tree lands.
- Link every PR and commit; never leave a bare number that does not resolve.
