# M1 `.5` stage-one qualification

This repository-owned record captures the durable, non-secret result of the owner-approved `.5` physical stage-one execution on the named private `MacBookPro18,3` / `apple,j314s`, plus the subsequent owner-operated 1TR boot outcome. It deliberately excludes credentials, account names, network addresses, process identifiers, screenshots, private temporary paths, and reusable authorization material.

This is evidence, not authorization for another execution, publication, or support claim.

## Approved identity

- App version/build: `0.5.0 (5)`
- Approved plan: `ea9736b214ff292569246020af8d509a76e3df54ab16803f0aeb93cee41d4277`
- Approved binding: `sha256:513b1b95c9dc9a866366427d2896d900fc2f31c13f8244958519a7efea23f26e`
- Target: `apple,j314s`, internal `disk0`, source `disk0s2`
- Approved extent: offset `857747943424`, length `137438953472`, exclusive end `995186896896`
- Pre-mutation normalized disk identity: `01f490cd26bd559e704944a993e603e046029fdc0d40e7013484fd60b6cf0235`
- Engine: 22,069,312 bytes, SHA-256 `992f4c7b6090b3f6eb71876d151336f29becc0c2a97a871c4cba04910d98cb99`
- Full-OS package: 3,627,102,006 bytes, SHA-256 `1ff85bfb1d86a0695a5c6192598df65af4b8af7e03385b4cc50154d9e3a70159`

The app and helper passed reciprocal Apple Development signing checks before the exact plan was submitted. The secure authorization value was neither read nor captured. The supported UI submitted one Start action and one matching destructive confirmation.

## Execution and containment

The helper accepted one request. The pinned engine completed without an engine or helper failure, and its root-only handoff was removed after consumption. The approved extent was consumed exactly and contiguously:

| Partition | Offset | Size | Exclusive end |
| --- | ---: | ---: | ---: |
| Asahi APFS stub | 857747943424 | 2499805184 | 860247748608 |
| EFI | 860247748608 | 524288000 | 860772036608 |
| Boot | 860772036608 | 2147483648 | 862919520256 |
| Root | 862919520256 | 132267376640 | 995186896896 |

The resized macOS source ended exactly at the approved extent start. The final normalized disk identity after stage one was `59bb8f9aeb304a3978c2305d86532bdf7d99d3483a5407f0195b7933d4d5098c`.

## Installed-content read-back

- `m1n1/boot.bin`: 6,205,289 bytes, SHA-256 `bb6829c44d8de26d6615406b41edc0beef2254766b5ed114afad2029db7ae856`
- `EFI/BOOT/BOOTAA64.EFI`: 217,088 bytes, SHA-256 `8028d3b82f1797cdddfcaaa0ceb12b9ce5a251514266c7532f3715f69401e5a0`
- The Asahi stub contains `.IAPhysicalMedia`, `Finish Installation.app`, `step2_launcher.sh`, `step2.sh`, and the boot-policy `boot.bin` resource.
- The Boot partition size matches `boot.img`; the Root partition contains the expandable `root.img` and ends exactly at the approved extent boundary.

## Owner-operated 1TR boot outcome

Stage one finished with the complete `.5` Omarchy system written and requested shutdown into One True Recovery. The owner completed Finish Installation, selected the Omarchy volume, and proved the boot-policy, m1n1, kernel, and initramfs path. The initramfs then reported `[FAILED] Failed to start Switch Root`, could not open a console because the root account was locked, and stopped before the installed system started.

Read-only package diagnosis reproduced the failure predicate: `.5` GRUB content selected a disposable builder-local `root=/var/cache/omarchy-asahi-package.../root.img` path instead of the installed Root filesystem UUID. The local repair creates a fail-closed `/dev/disk/by-uuid/<root-uuid>` view while finalizing boot, requires every Linux entry to contain `root=UUID=<installed-root-uuid>`, and rejects any builder-local root selector before sealing. Those local tests are repair evidence only; they do not qualify a new physical payload.

The preserved `.5` package is disqualified from another execution. A new reproducible full-OS package, engine/app/catalog qualification, fresh signed-plan review, and explicit owner approval are required before any further physical mutation. Installed-system verification and macOS coexistence remain unproven.
