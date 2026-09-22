# Apple Silicon integration reference

Supporting detail for the [upstream integration plan](upstream-integration-plan.md), retained during its September 19, 2026 simplification. Use the plan for the agreed direction and contributor proposals. This reference preserves dated observations, validation constraints and tracking records; it does not establish current package availability, PR status or release readiness. Recheck dated observations before acting on them.

## Add-on extraction record

The candidate began with Wi-Fi recovery, then added the other components. The package-refactor delta at `20b8ae0f` removes 1,213 desktop lines against `350c4655`, including compatibility wrappers, the optional mapper guard and regression tests. The subsequent general menu-test repair adds 61 test lines, giving a combined desktop reduction of 1,152 lines. The unsuccessful audio-restart workaround is excluded. The cleaned history introduces the package directly, with separate desktop interfaces, integration and migration commits; its implementation matches the tested candidate. Counts exclude package source, plans and documentation. An upstream desktop submission must omit `packages/`. See the [validation report](../plans/omarchy-mac-package-validation.md) for exact revisions, successful package/boot checks and remaining limits.

## Package delivery observations

The release delivery decision is to use [omarchy-mac/omarchy-pkgs-aarch64](https://github.com/omarchy-mac/omarchy-pkgs-aarch64), completing its signing and package-transition work. The pool observations and questions below support a separate exploration of independent sub-team experiments; resolving them is not a release prerequisite.

### Pool inspection

The 2026-09-17 inspection found that the pool provides upstream mirrors, a Factory for additional builds, signed databases, and documented promotion/testing workflows. Its official Omarchy ARM source contained the same 115 package names counted in official edge. Asahi sources were present in the inspected edge inventory but absent from its RC/stable inventories. Pool ring names are distinct from official Omarchy channel names.

The pool setup inserts its include above `[core]` and retains existing sources. Review the complete resulting configuration, including older fork repositories, before using it for a release. Decide whether to adopt a coherent pool-managed base or a supplemental collaboration collection; do not assemble an accidental mixture through fallback sources.

In that inspection, the aarch64 edge configuration endpoint returned no repositories with no source selection, with `with=asahi`, and with `with=asahi,asahi-alarm`; RC and stable each returned five repositories. Recheck these results before making a delivery decision. Resolve this configuration/publication issue with the pool maintainer before directing testers to edge setup. Provide the tested URLs, release identity, and responses.

### Package inventory and builds

Create a manifest mapping each required package to its provider, source commit, recipe, version, architecture, signer, and purpose. Distinguish baseline requirements from optional applications; an absent optional package need not block first encrypted-install validation.

The 2026-09-17 inventory identified the following publication worklist. These are dated observations, not a current availability guarantee; the add-on row reflects the subsequent implementation decision:

| Package | Recorded publication gap |
| --- | --- |
| `cursor-bin` | Absent from official ARM edge; present in the fork's unsigned GitHub-release repository |
| `avd-fw` | Absent from official ARM edge; present in the fork repository |
| `libva-v4l2_request-avd` | Absent from official ARM edge; present in the fork repository |
| `obsidian-appimage` | Absent from official ARM edge; present in the fork repository |
| `omarchy-steam-fex` | Absent from official ARM edge; present in the fork repository |
| `pinta` | Absent from official ARM edge; present in the fork repository |
| `vi` | Absent from official ARM edge; present in the fork repository and reported among the pool's Factory builds |
| `omarchy-mac` | New add-on candidate supersedes the unresolved `omarchy-settings-asahi` request. Recipe and artifacts exist; signed collaboration publication remains open |

Marcelo's [package repository](https://github.com/maralcbr/omarchy-pkgs) is an existing source of Apple Silicon settings work. Checked 2026-09-17: runtime channel 32 points to `asahi-quattro-a67d7f78`, which publishes `omarchy-settings-dev-4.0.3.r6962.ga67d7f7-1-aarch64.pkg.tar.xz` and its detached signature. The inspected `asahi-quattro` recipe provides `omarchy-settings`, but does not declare `omarchy-settings-asahi`; the inspected release assets and latest listed stable supplemental database did not contain that separate name. The cleaned shared branch changes that explicit request to `omarchy-mac`; the earlier baseline contained the old requirement. Deliver the matching runtime/settings/add-on package set before directing testers to the transition. Reconcile the intended package set and publication path with Marcelo. Reuse his settings work, while checking file ownership and compatibility with our recorded runtime/settings pair before selecting a package for the collaboration channel.

Begin recipe and publication work from this inventory and update entries as packages land. Use the listed alternate providers where appropriate. Asahi already supplies its kernel, audio components, and Widevine. Prioritize packages required for the baseline installation ahead of optional applications.

Build the selected runtime/settings pair from the same recorded `quattro-upstream` revision. Testers should receive a packaged system; contributors can continue dev-linking for development. Do not assume mirrored official `omarchy` packages contain the team's branch changes.

### Questions for the pool maintainer

- Can participating teams select a collection or channel with approved package overrides and independent promotion criteria?
- Can the Factory build the runtime/settings pair and Mac extras from exact source and recipe commits?
- How are complete release sets pinned, retained, retrieved, and withdrawn, including dependencies needed to reproduce installer images?
- Who reviews recipes, approves builds, and promotes Mac releases? What is the operational fallback if the service or a maintainer is unavailable?
- How are package and database signing keys authenticated, rotated, and recovered? Factory package signatures must be accounted for alongside mirrored upstream signatures.
- Why does aarch64 edge configuration return no repositories regardless of the tested `with=` selections, while RC and stable are populated and edge databases exist?
- How do testers enter and leave the collaboration collection without unresolved dependencies or an unintended mixture of versions?

### Signing and transition

At the recorded `350c4655` baseline, architecture-aware templates point at official ARM edge while the Apple setup leaf and migration `1788200000.sh` can add an `[omarchy-aarch64]` source with `Optional TrustAll`. The ARM channel qualification allowlist is empty. Inventory the effective configuration on each installation path; the presence of a repository database is not qualification, and changing future source files does not repair previously written configuration.

Use authenticated signing keys and signature enforcement for the shared release path. Replacing `Optional TrustAll` is a deliverable. The [existing signing issue #394](https://github.com/omacom/omarchy-mac/issues/394) records the gap. Complete signing for the existing `omarchy-pkgs-aarch64` delivery path; the release and packaging maintainers need to confirm an owner. Any later pool experiment must define its own trust and signing arrangements. Raising the issue does not establish responsibility for implementing its solution.

Trust initialization belongs in installer/package configuration. Upstream runtime changes should not hardcode trust in a temporary private service. Document all actual trust roots, including Arch Linux ARM and Asahi, official Omarchy and the collaboration source. Include the pool's database and Factory signing if a tested configuration uses them.

Retire the unsigned repository leaf only when its replacement works for both fresh installations and existing testers. Deleting the leaf and migration from a future source branch does not remove a stanza already written to a user's machine. Provide a separately tested transition that installs the required keys, changes repository order, replaces packages where necessary, and removes obsolete configuration without stranding users.

Qualify each exact tested configuration. A successful run with pool-built overrides validates that collaboration configuration; it must not be presented as proof that official ARM edge alone is qualified. Record the repository URLs, ordering, signatures, package identities, and test environment with the result. Coordinate official ARM qualification and future RC/stable publication with upstream maintainers in parallel.

## Installer recovery constraints

The September 21 installer direction prioritizes qualification of Marcelo's image-first encryption flow; the temporary tail installer remains a fallback pending that decision. Installation, encryption conversion, re-keying and any reclamation must be explicit, restartable state machines. Keep durable progress and revalidate the actual disk state before each mutation; a progress marker alone does not authorize a write.

For image-first installation, test interrupted encryption conversion, owner re-keying, recovery-key acknowledgment and factory reset. Verify that retries preserve the intended keyslots and that completed provisioning removes temporary unlock keys from unencrypted artifacts and boot configuration. No reusable unlock credential may remain in logs or unencrypted boot files after completion. Keep personal data out of the system until encryption and owner setup are complete.

If the tail-installer design is selected, test interruption before and after installer-partition deletion, root-partition growth, encrypted-mapping resize, and filesystem growth. A retry must recognize completed stages without deleting or formatting a different partition. Validate exact identities and geometry, not labels alone. Preserve unrelated Linux installations, macOS, and recovery partitions.

For that tail-installer design, retain the temporary installer until a successful independent installed boot. Document recovery for failed installation, failed first boot, interrupted reclamation, and failed updates. Reclamation should leave an already bootable installation recoverable even if subsequent growth steps fail.

Resolve package-managed kernel/initramfs ownership and ESP update hooks as part of this work. The existing UUID-private ESP design and managed-kernel-update proposal are inputs to review, not a requirement to retain that exact layout. Test snapshot recovery together with the kernel/modules state, because restoring an encrypted root does not necessarily restore external boot files.

Evaluate Marcelo's `omarchy-mac-boot` package against the selected boot layout rather than applying it unchanged to the ISO's UUID-private ESP layout. Snapshot restore remains experimental until its interrupted root-switch behavior and external-kernel compatibility are qualified; retain the opt-in gate and test refusal of incompatible snapshots.

The existing bootstrap may remain a developer or recovery route. Describe encryption only for the exact qualified path; do not require two equally supported public installers. The recommended release path must meet the encrypted lifecycle in the [plan](upstream-integration-plan.md#installer).

## Upstream merge record

### Merge tracker

This is the set of upstream contributions we are advocating for the collaboration system. Upstream PR status and inclusion in our branch are tracked separately: a change can be running successfully here while its upstream PR remains open. The table below is a historical snapshot: PR statuses and head revisions were checked on 2026-09-17 and have not been revalidated for this document revision. Inclusion was checked at `0f5cb383`, an ancestor of the current `350c4655` baseline; adapted or cherry-picked equivalents need not share the upstream commit hash.

| Contribution | Upstream source branch and checked head | Upstream status | In the collaboration branch? | Next action |
| --- | --- | --- | --- | --- |
| [#9835 — Apple Silicon foundation](https://github.com/omacom/omarchy/pull/9835) | `maralcbr:omacom/asahi-overlay` — `980ce7eb` | Open | Yes, rebased/adapted foundation including the availability, pacman, keyring, and settings work | Coordinate Marcelo's review; compare the final merged tree and retain only our remaining delta |
| [#12056 — Provisioning robustness](https://github.com/omacom/omarchy/pull/12056) | `scottjones:pr/provisioning-robustness` — `400dad0d` | Open | Yes, equivalent first-run, DMI, and locate-test fixes | Continue upstream review independently of the Apple platform submission |
| [#12058 — Battery rounding](https://github.com/omacom/omarchy/pull/12058) | `scottjones:pr/battery-rounding` — `9aa09a0b` | Open | Yes, rounding commit `305a4b3e` | Continue upstream review; keep separate from the Apple-specific platform delta |
| [#8942 — Clock/weather popup anchoring](https://github.com/omacom/omarchy/pull/8942) | `scottjones:panels-anchor-to-widget` — `7a341007` | Open | Yes, equivalent commit `be1c114b`, pushed to `quattro-upstream` | Advocate the existing general-desktop PR; keep it out of D. Five focused tests passed, and Scott confirmed the live result after shell reload |
| [#9834 — Refuse shell tests as root](https://github.com/omacom/omarchy/pull/9834) | `maralcbr:omacom/no-root-mount-tests` — `79c919b9` | Open | Yes, cherry-picked as `0f5cb383` with Marcelo's authorship and source reference preserved | Advocate Marcelo's existing PR separately from D. Syntax checks and the normal-user Windows VM regression test pass; unprivileged user-namespace checks verify runner root refusal, the explicit fixture-only override, and unconditional Windows mount-test root skipping |

Additional work to prepare for submission:

| Work | Branch or component | Collaboration status | Submission path |
| --- | --- | --- | --- |
| Remaining Apple platform support (D) | `pr/apple-silicon` — `e0b622a2` | Included; this extraction branch does not contain [#8942](https://github.com/omacom/omarchy/pull/8942) | Prepare the remaining delta after reconciling [#9835](https://github.com/omacom/omarchy/pull/9835) and package prerequisites; no upstream PR recorded yet |
| Keyboard ambient-light control (E) | `pr/keyboard-als` — `071e54e8` | Equivalent integration commit `785ba933` included | Prepare an independent PR; no need to wait for unrelated installer work |
| Steam/FEX | `omarchy-steam-fex` package and desktop integration | Desktop integration included; package publication/signing remains part of the delivery work | Track the package recipe/publication and any separate runtime submission; `pr/steam-fex` now points at D and is not a separate active series |
| Required Mac packages | Dated publication worklist above, updated for the add-on design | Dependencies have mixed publication/signing status | Add recipe PR links, build revisions, and published versions as submissions are created |
| Encrypted installer and Aurora integration | Installer projects and package catalogs | Implementation and lifecycle validation work remains | Track in those projects; do not fold their source into the desktop PR |

Update this tracker when a PR head changes, a change enters the collaboration branch, or upstream merges or closes a submission. Record the integrated revision and validation outcome. After an upstream merge, compare its final implementation with our copy, reconcile differences, and remove redundant downstream changes during the next integration. Keep merged rows with their merge revision until that reconciliation is complete. A closed or superseded PR needs an explicit disposition rather than silently disappearing from the list.

### Remaining work

| State | Work |
| --- | --- |
| Already present locally | Explicit `omarchy-pkg-available` menu guards; architecture-specific preinstall and xpadneo targets; `test/fixtures/optional-aarch64-required`; rebased pacman/keyring work from [#9835](https://github.com/omacom/omarchy/pull/9835); packaged Steam launcher integration |
| Still required | Complete the `omarchy-pkgs-aarch64` delivery path; signed branch builds; publication of required missing packages; tested repository transition; encrypted installer integration and kernel update ownership; Aurora assumption audit |
| After upstream changes | Compare the actual merged [#9835](https://github.com/omacom/omarchy/pull/9835) tree and subsequent upstream commits against the integration branch, reconcile differences, and extract remaining submissions |

Use tree comparisons and range-diffs against the actual upstream merge to identify equivalent changes, resolve conflicts, and determine the remaining contribution. Run relevant tests after reconciliation.

Continue [#12056](https://github.com/omacom/omarchy/pull/12056) and [#12058](https://github.com/omacom/omarchy/pull/12058) through review and coordinate [#9834](https://github.com/omacom/omarchy/pull/9834)/[#9835](https://github.com/omacom/omarchy/pull/9835) with Marcelo. Independent fixes and package recipes can land while installation work proceeds. Prepare the remaining Apple platform contribution with its real package dependencies and evidence; decide whether it is one PR or several based on the final scope and reviewer feedback. ALS and Steam-related changes retain their own review boundaries where useful.

Propose appropriate recipes for official `omarchy-pkgs` or the relevant upstream provider. Ask Ryan and the maintainers how ARM publication and qualification should work. Disclose temporary dependencies used during testing; do not describe the intended final official package set as if it already supplies the tested system.

## Relationship to existing Basecamp cards

Reconciled against the main RS 4.5 board and M+ Workstreams board on 2026-09-19. The main cards describe the wider release outcomes; the plan explains the integration between components; workstream cards hold their implementation and validation tasks. Preserve existing discussions and completed work when refining their scope.

| Part of this plan | Existing work to use | Reconciliation needed |
| --- | --- | --- |
| Distilled desktop, add-on extraction and upstream merge | [Linux-side installer integration](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10263384708) and the [upstream-merge task list](https://app.basecamp.com/5994298/buckets/48646031/todolists/10266878547), feeding the main unified-installer outcome | Add a bounded package-extraction/remaining-merge task under this existing effort, coordinated by Marcelo, Scott, Wes and Naeem; distinguish it from the installer handoff |
| Native installer and encrypted installation | [Native macOS installer](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10263384702), [Linux-side integration](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10263384708), [offline installation/encryption](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10277024969), and [VM/Try](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10263384722) | Define their shared handoff and exact package set; the Try flow is part of launch scope while advanced VM features need explicit release scope |
| Package delivery and signing | [ARM package infrastructure and migration](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10263384718), feeding the main Omarchy ARM initiative | Its board column is currently Related or Proposed, but the package delivery required by the release remains a dependency. Confirm its bounded release deliverable and signing owner |
| Kernel, graphics and peripherals | [M1/M2 enablement](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10263384726), [GPU/Mesa](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10277024959), [boot](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10310824433), and [external displays](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10263384730) | Identify one compatible delivered stack and its feature dependencies; reconcile the Apple proposal with the main unified-kernel card, currently assigned to Krzysztof Wilczyński |
| MLX and shared Mesa packaging | [M1/M2 MLX/ANE release](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10264591646) and [Honeykrisp packages](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10320749071) | Carry the bounded release criteria and Mesa dependency into this plan; agree the build, supported models and graphics/ML tests together |
| Touch ID and video | [Touch ID/Secure Enclave](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10310824384) and [video acceleration](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10310821731) | Update implementation and packaging evidence with DJ and the video contributors, including Chris; retain the existing Andreas/Miguel contributions and distinguish decoding from encoding |
| Early M3 desktop and Aurora preview | [Kernel and preview proposal in the plan](upstream-integration-plan.md#kernel-graphics-and-hardware-scope), existing boot/installer efforts and the main unified-installer beta scope | Add explicit preview delivery/validation tasks when the proposed package paths are agreed. The [M3 MLX/ANE card](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10320790748) is a different capability and must not become a dependency for a software-rendered M3 desktop |

Specific points to resolve with the card owners:

- Two cards have the same Honeykrisp package title: [10320749071](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10320749071) contains the detailed proposal; [10320749175](https://app.basecamp.com/5994298/buckets/48646031/card_tables/cards/10320749175) currently contains only “test,” but is the dependency linked by the MLX release card. Confirm the canonical card and repair the dependency rather than maintaining both.
- Josh's release card makes Honeykrisp a hard dependency and moves full macOS performance parity to a later card. The detailed Honeykrisp card still invokes a release performance-parity expectation. Agree the release performance criterion and tested package build so these requirements are consistent.
- AirDrop is in the First M+ official release column but is not named in Marcelo's release outline. Confirm whether it is a launch requirement or an additional feature; a column alone should not silently expand the release promise. Apply the same scope clarification to advanced virtualization work.
- Several kernel, installer and package card descriptions still present September 6 snapshots. Ask their contributors to update them from current work; those older descriptions do not establish that a feature is still missing or has since shipped.
- Keep newer-chip MLX, full performance parity, the voice assistant, Apple development tools and vintage-Mac support connected where they share dependencies, while retaining their distinct release scope. Their unfinished roadmap should not implicitly block the bounded Apple Silicon release.

These are proposed reconciliations. No Basecamp cards have been moved, reassigned, merged or marked complete as part of this document revision.

## Sources

- [Shared branch](https://github.com/omacom/omarchy-mac/tree/quattro-upstream); upstream PRs [#9834](https://github.com/omacom/omarchy/pull/9834), [#9835](https://github.com/omacom/omarchy/pull/9835), [#12056](https://github.com/omacom/omarchy/pull/12056), [#12058](https://github.com/omacom/omarchy/pull/12058), and [#8942](https://github.com/omacom/omarchy/pull/8942).
- [Official ARM edge database](https://pkgs.omarchy.org/edge/aarch64/omarchy.db); [fork package repository](https://github.com/omarchy-mac/omarchy-pkgs-aarch64); [signing issue #394](https://github.com/omacom/omarchy-mac/issues/394).
- [Pool](https://omarchy-pool.firemanxbr.org/), [source](https://github.com/firemanxbr/omarchy-pool), [live inventories](https://omarchy-pool.firemanxbr.org/api/v1/stats), and [security model](https://omarchy-pool.firemanxbr.org/docs/security-model).
- [Marcelo's macOS installer source](https://github.com/maralcbr/omarchy-mx-mac/tree/main/apps/omarchy-apple-installer) and [project documentation](https://github.com/maralcbr/omarchy-mx-mac); [omarchy-mac-iso](https://github.com/omarchy-mac/omarchy-mac-iso), including its managed-kernel-update proposal; local prepared-install work under `~/code/omarchy-mx-mac-integration/apps/omarchy-apple-installer/Engine/overlay/`.
