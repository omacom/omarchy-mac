# Apple Silicon hardware evidence

One directory per record, named `<date>-<subject>`, holding a `README.md` that says what was observed, on which Mac, from which inputs, and what the record does not claim. Small text captures (JSON reports, journals, inventories) sit beside it.

Bulky or binary artifacts (build logs, state archives, images) are never committed. They live at an immutable location and `artifacts.tsv` pins each one by path, byte count, SHA-256 and URL. The URL must not be able to move: a GitHub raw URL at a full commit, a GitHub release asset, or a content-addressed object in the R2 bucket. The path names the record the artifact belongs to, as if it sat beside that record's README.

`tools/hardware/evidence-verify` checks both rules: committed files stay text and at most 64 KiB, and every artifact entry is well formed and pinned. `tools/hardware/evidence-verify --fetch` downloads each artifact and compares its size and hash.

## Records carried over from omarchy-mx-mac

The seven records dated 2026-08-27 to 2026-08-29 were copied byte for byte from `maralcbr/omarchy-mx-mac` at `cf0606c65cce20f123eb37cf465eacdb6168862b` (`evidence/apple-silicon/`), so the hashes their READMEs quote still hold. Their text speaks from that repository: "this directory" and "beside this file" refer to the original layout. Their three bulky artifacts stay in that repository at that commit and are listed in `artifacts.tsv`.

## Adding a record

1. Run the checks in [`docs/apple-silicon-hardware-validation.md`](../../../docs/apple-silicon-hardware-validation.md) and keep the report `tools/hardware/remote-check` prints.
2. Write the record's `README.md`: date (with time zone), Mac model and board, kernel and boot packages, what passed, failed or was not tested, and the inputs it binds (commits, candidate hashes).
3. Leave out credentials, account names, network addresses and private paths.
4. Upload anything bulky to an immutable location, add it to `artifacts.tsv`, and run `tools/hardware/evidence-verify --fetch`.
