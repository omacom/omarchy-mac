# VM acceptance

KVM acceptance harnesses for Apple Silicon Omarchy, run on an aarch64 Linux host such as the Omarchy side of a test Mac. They qualify packages and images in disposable guests; physical hardware is qualified separately.

- [`asahi-fresh/`](asahi-fresh/README.md) installs a package set from scratch in a generic aarch64 guest and runs the fresh-install lifecycle: interruption recovery, reboot, verification, optional packages and a rejected rerun.
- [`mac-image/`](mac-image/README.md) boots a built Mac image and proves its plain and encrypted first boots.
- `keys/omarchy-arm-repository.asc` is the public key that signs the package candidates and Mac images the harnesses verify.
- `test/asahi-fresh-run-test.sh` covers the `asahi-fresh` runner with Docker, SSH and QEMU stubbed out. Run it as a normal user on Linux (it needs `flock` and GNU coreutils).

Both write verified evidence to `~/vm-evidence/<run-id>/` (`mac-image-<run-id>/` for images), with the hashes an acceptance record takes in `run.txt`. A passing `asahi-fresh` run deletes its ~23 GB run directory; a failed run keeps it under `asahi-fresh/test-runs/runs/<run-id>/` (images: `~/vm-mac-image/runs/<run-id>/`) until you delete it. Check for 10 GiB free before a run, since updates on the host refuse below that.

## Provenance

Moved from maralcbr/omarchy-mx-mac at `8e70a5cdcc82caf2a0548d742bb1b26e40876a37` (2026-09-25): `test/vm/` became `asahi-fresh/` and `mac-image/`, `default/omarchy-arm-repository.asc` became `keys/`, and `test/shell.d/asahi-fresh-vm-run-test.sh` became `test/`. The first commit touching this directory is that copy unchanged; its earlier history is `git log 8e70a5cd -- test/vm` in omarchy-mx-mac.

The move changed only what tied the harness to living inside an omarchy-mx-mac checkout:

- `asahi-fresh/run` takes the omarchy-mx-mac tree under test with `--source DIR` (or `OMARCHY_VM_SOURCE_DIR`) instead of the checkout around it, and records its commit as `source_commit` beside `harness_commit`.
- Both harnesses verify signatures with `keys/omarchy-arm-repository.asc` unless a key file is named.
- `mac-image/run` records `harness_commit` in `run.txt`.

The guest and container scripts are unchanged, and so are the defaults: the dated Arch Linux ARM snapshot on R2, the channel pointers, the maralcbr/omarchy-pkgs release URLs, the guest size, and the host lock `/tmp/omarchy-asahi-fresh-vm.lock`, which runs from either repository share.
