# Direct Asahi Install VM

This harness tests the published fresh Omarchy 4 lifecycle in a disposable
generic aarch64 KVM guest. It verifies the signed public assets unchanged, then
runs the current source candidate with only its hardware predicates patched in
a retained test copy. The installed Apple
detector is overridden while system setup runs and restored byte-for-byte
afterward. A temporary SSH firewall allowance supports post-reboot assertions
and is removed by the final rerun check. No VM bypass is shipped in the
production installer.

The guest installs the real Asahi package set while continuing to boot an
unowned generic `linux-aarch64` test fixture through GRUB. This validates package resolution,
the exact six-package transaction, pinned source builds, failure recovery, user
provisioning, hard-interruption recovery, collision safety, reboot, safe
completed reruns, migrations, and protected boot
files. It cannot validate
Apple GPU, Wi-Fi, audio, suspend, or other physical hardware behavior.

Run:

```bash
test/vm/asahi-fresh/run
```

The guest uses 8 vCPUs, 6 GiB RAM, and a 96 GiB sparse disk. Set
`OMARCHY_VM_CPUS` or `OMARCHY_VM_MEMORY_MB` explicitly when a different
disposable-guest limit is required; benchmark a run before changing the 8 vCPU
default.

The guest takes its Arch Linux ARM packages from a dated, immutable copy of the
`core`, `extra`, `alarm` and `aur` repositories in our own bucket, not from the
live mirrors, so a mirror caught mid-transition (one package rebuilt against a
new library, its dependents not yet) cannot fail a run that has nothing to do
with it. The default is the snapshot the current payload was built against;
`OMARCHY_VM_ALARM_MIRROR` overrides it with another mirror URL (any `https://`
URL naming `$repo` and `$arch`, so a live Arch Linux ARM mirror works too). Only the signed base rootfs still comes from a live mirror. See
`docs/apple-silicon-distribution-channels.md`, "The Arch Linux ARM snapshot".

Use `--rebuild-base` to discard the cached Arch Linux ARM base. State is kept
in `test/vm/asahi-fresh/test-runs/` (ignored by Git; `OMARCHY_VM_STATE_DIR`
moves it): the cached base, the guest SSH key, and one `runs/<run-id>/`
directory per run holding the guest disk (about 23 GB by the
end of a run) and its logs.

Each run gets an ID (`OMARCHY_VM_RUN_ID`, by default the UTC start time and
process ID) and its own `omarchy-asahi-fresh-vm-<run-id>` container. Cleanup
removes only the container ID that its own `docker run` recorded, so a run never
removes another run's VM or directory. A run holds the host lock
`/tmp/omarchy-asahi-fresh-vm.lock` from start until its evidence is exported and
its directory cleaned up. The path is fixed, so every checkout, user and `sudo`
meet the same lock. One user runs VM acceptance on a host: the first run
creates the lock 0644 for its user, and a lock file anyone else owns is refused,
since its owner could replace it while a run holds it. A run also checks, once
it holds the lock, that the path still names the file it locked. A second run
is refused with the holder's run ID, user and state directory;
`--wait-for-lease` queues it instead. A run also refuses to start while any container still forwards its
SSH or VNC port (`OMARCHY_VM_SSH_PORT`, `OMARCHY_VM_VNC_PORT`), such as a VM
kept with `--keep`. The state directory belongs to the user who created it: a
run as anyone else is refused, and its `lease` file keeps a second run out even
past the host lock.

When a run ends, pass or fail, it stops the VM and copies its evidence to
`~/vm-evidence/<run-id>/` (`--evidence-dir DIR` or `OMARCHY_VM_EVIDENCE_DIR`
changes the parent, which must be outside the state directory): the logs an
acceptance record hashes
(`candidate-repository.log`, `install.log`, `serial.log`, `verify.log`,
`optional-packages.log`, `rerun.log`), `optional-package-logs/`, the final
`desktop.ppm`, `SHA256SUMS`, and `run.txt` with the run's inputs, its result and
the `*_log_sha256` lines an acceptance record takes. The copy is checked
against hashes of the originals and only then renamed from `<run-id>.partial`.

- A passing run then deletes its run directory.
- A failed run keeps its run directory for debugging; `--discard-failed-run`
  deletes it once the evidence is exported. Remove kept directories by hand when
  done; each run lists the ones still on disk. A run's disk is backed by the
  run's own `base.qcow2`, a hard link to the cached base it started from, so a
  kept disk stays usable after `--rebuild-base` or a new base replaces the
  cached one (the old base's space is then held until the kept run is removed).
- An export that does not verify keeps the run directory and fails the run.
- A container that cannot be confirmed removed may still be running its guest
  on the run directory, so the run exports nothing, keeps everything, and
  fails.
- `--keep` leaves the VM running in its container on its run directory,
  pausing the guest while the evidence is copied.

Use `--optional-packages` to install every transaction in
`install/optional-packages-aarch64-required` with real `pacman -S` operations
after the reboot checks. Each transaction gets a separate log under
`optional-package-logs/` in the evidence directory. This validates package
installation and post-install hooks in a disposable system, but it does not
automate application login, GUI interaction, or hardware behavior.

To run the full lifecycle after installing an exact immutable package candidate,
provide its trusted identity explicitly:

```bash
OMARCHY_VM_CANDIDATE_TAG=asahi-packages-candidate-<40-hex-commit> \
OMARCHY_VM_CANDIDATE_SHA256=<64-hex-descriptor-checksum> \
OMARCHY_VM_CANDIDATE_FINGERPRINT=<40-hex-signing-subkey> \
OMARCHY_VM_CANDIDATE_PACKAGE_COUNT=<exact repository package count> \
test/vm/asahi-fresh/run
```

This opt-in path verifies the signed descriptor inside the guest, installs all
the declared candidate packages through the exact release repository, and checks their
versions again after the full install and reboot. The fresh installer's
repository bootstrap keeps that candidate `Server` and only repairs the section
around it, so the run ends on the candidate with no promoted-set record.

Before the guest starts, `run` resolves the Apple Silicon package channel once
(the `asahi-packages-channel` pointer, then the GitHub release listing) and
hands the guest that exact channel for the installer's repository bootstrap.
Without a candidate, `guest/verify` then requires `[omarchy]` to lead the
repositories on that channel's stable set, recorded in
`/var/lib/omarchy/asahi-package-repository`, so a promotion during the run
cannot fail it.

Pacman does not fail a transaction whose initramfs hook fails, so right after
the candidate transaction the guest runs `/usr/bin/mkinitcpio -p` for every
preset and stops on the first failure. Each image a preset names must exist
and, when `90-omarchy-asahi.conf` is installed, contain `omarchy-vendorfw.sh`
and its initrd unit. It bypasses the `/usr/local/bin/mkinitcpio` wrapper from
`limine-mkinitcpio-hook`, which discards the exit status. Unified kernel images
are not covered: `*_uki` outputs are not inspected, and a preset that names no
`*_image` stops the run.

When the candidate also contains a new runtime that is not yet published on the
stable channel, additionally set `OMARCHY_VM_RUNTIME_MANIFEST_SHA256` to the
trusted SHA-256 of `asahi-quattro-bundle.manifest` and `OMARCHY_VM_RUNTIME_SOURCE`
to its exact runtime source commit. Both values are required together with the
package candidate identity. The guest verifies the manifest signature and all
six runtime package signatures/checksums, checks the product version, and binds
the source installer to the signed package's installer bytes.

This runtime-candidate path creates an explicitly named VM-only release fixture
with sequence 1. It tests fresh installation, recovery and reboot of the exact
candidate bytes; it does not claim to test a published runtime-channel descriptor
or public channel promotion. Omitting the runtime pins retains the published
stable-channel path. The VM allows SSH before applying the firewall defaults
and removes that test-only rule in the final rerun stage.

The post-reboot updater check normally discovers the live channel through the
anonymous GitHub API, whose quota a shared office IP can exhaust. Set
`OMARCHY_VM_ASAHI_CHANNEL_URL` to
`https://github.com/maralcbr/omarchy-pkgs/releases/download/asahi-quattro-channel-<N>/asahi-quattro-channel`
to skip that lookup; the updater still verifies the channel's signature,
sequence and manifest. Any other value stops the run before the VM starts.
