# Physical M1 Pro stage-one plan review

This folder records a read-only plan generated on the physical
`MacBookPro18,3` (`apple,j314s`) before helper registration or disk mutation.
It belongs to the active `omarchy-mx-mac` project. It is not evidence from the
historical `omarchy-mac` reference fork.

## Approval state

- Owner destructive gate: approved for the physical M1 Pro only.
- This specific plan: superseded; do not execute it.
- Privileged helper: not registered.
- Stage-one execution: not started.
- Partition map after the probe: unchanged (`disk0s1`, `disk0s2`, `disk0s6`).
- Recovery container: retained and outside the approved extent.

The app later failed `Prepare signed plan` before helper registration. A
read-only engine replay proved that the layout digest incorrectly included
APFS minimum-size safety bounds, which can drift during normal APFS
housekeeping even when partition geometry is unchanged. The `.2` engine
therefore rejected the candidate-bound plan as `invalid plan`. No privileged
request or disk operation occurred.

The source fix makes layout identity cover immutable geometry only while plan
and execution admission continue to recheck the current minimum install and
container bounds. A new immutable `.3` engine and fresh catalog must produce a
new plan and evidence folder before stage-one execution.

## Exact candidate-bound plan

- Source: resize `disk0s2` in physical store `disk0`.
- Approved extent: byte `857747943424` through `995186896895`.
- Allocation: `137438953472` bytes (128 GiB).
- Resulting macOS APFS-container size if executed: `857223630848` bytes
  (approximately 798.352 GiB).
- Plan digest:
  `beaadc221960bd47ba46dbd14dd9b253a96cba38a59cbf80ac341d6a8d72f305`.
- Candidate-binding digest:
  `sha256:5f310846b2b9cdb0b4ab6309b7dbc0bb3389307dcf2bff7382d3d4a9a0ac9a2f`.

The superseded implementation would have re-inspected the live layout and
failed closed if the source,
extent, layout digest, catalog, artifacts, plan, or binding no longer matches.
The stage-one sequence resizes the macOS APFS container, creates the Asahi APFS
stub target in the released extent, installs the stub and EFI environment, and
then stops at the One True Recovery handoff. The machine owner must enter
Recovery and authenticate before boot-policy approval can continue.

`plan.json` remains the verbatim structured report emitted by the temporary
read-only probe, with the probe identity added. The probe and its scratch
directory were removed after capture. It is retained as failure-analysis
evidence, not as an executable authorization artifact.
