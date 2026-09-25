# Experimental Asahi HDMI reconnect recovery

This is an opt-in downstream kernel candidate for Omarchy Mac, not an installer migration or a replacement for the distributed `linux-asahi` package. The functional patch is under [`patches/asahi/`](../patches/asahi/apple-dcp-hdmi-reconnect.patch). It is pinned to [AsahiLinux/linux `ce9f2eba72c061a50b2d790450e90af3439d8c24`](https://github.com/AsahiLinux/linux/commit/ce9f2eba72c061a50b2d790450e90af3439d8c24); do not apply it blindly to another revision. It does not implement USB-C DisplayPort support or M3 enablement.

## Failure and repair

On the affected HDMI/DP2HDMI path, disconnect can power down firmware and invalidate the mode while DRM still considers the CRTC active. The diagnostic first reconnect submitted with `active=1`, `active_changed=0`, `mode_changed=0`, and `valid_mode=0`. Firmware swallowed swap 3339 and DRM subsequently timed out. The unplug event associated with swap 3338 **was delivered** through synthetic vblank; the trace does not support blaming that old event for the reconnect stall.

The patch introduces an HDMI disconnect generation, requests a real modeset before `drm_atomic_helper_check`, and performs recovery power-on before programming the mode even when DRM active state did not change. It propagates power-on allocation/timeout failures and consumes only the captured generation after successful power/mode completion. A newer disconnect remains pending. A flush-time guard withholds a swap while recovery is pending, using the driver's existing owned-event/synthetic-vblank path. TEST_ONLY does not perform firmware IO or consume recovery, and the patch does not fabricate `active_changed`, shorten DRM timeouts, or directly complete DRM completions.

This is not full serialization of hotplug and asynchronous submission. See the open validation items below.

## Reproducible source and seam tests

Run from an Omarchy Mac checkout with Python 3, Git, a C11 compiler named `cc`, and HTTPS access:

```bash
python3 test/asahi/reconnect.py
bash test/shell.d/asahi-hdmi-reconnect-test.sh
```

The first command downloads only the seven affected source files at the pinned commit, verifies their SHA-256 manifest, applies the exact patch in a temporary Git repository, and runs the source invariants and extracted-C seam. With a local kernel repository containing the commit, use `python3 test/asahi/reconnect.py --source /absolute/path/to/linux` to avoid downloads. It reads baseline Git blobs, not that repository's working files, and never modifies the supplied source. Baseline must compile and report exactly 11 failed seam assertions; patched code must report zero failures and pass both source tests. Compiler/download failures are not accepted as a RED result.

The C seam executes extracted driver functions but mocks DRM, firmware, atomics, and workqueues. It covers unchanged-active reconnect, modeset permission, no firmware IO during check, power/mode errors, a newer generation during mode ACK, flush withholding, disconnected recovery, and exclusion of non-HDMI displays. It does not model concurrency, firmware, full DRM transactions, framebuffer lifetimes, or actual vblank delivery. CI runs this separately from `test/all`; the offline build-contract test is picked up by `test/shell`.

## Opt-in build integration

There is no kernel package recipe on the current `quattro` branch to modify in place. The supplied build-only wrapper and package recipe deliberately remain outside the normal installer/update path. They never run package installation, modify GRUB, or reboot.

Use a native aarch64 Arch/Asahi build host as an unprivileged user, with the toolchain and build dependencies required by the pinned Asahi kernel (including its matching Rust toolchain when enabled), `makepkg`, Python 3, Git, `cc`, `bsdtar`, and `zstd` already available. Export the toolchain's PATH before invoking the wrapper. Supply a known-good Asahi kernel configuration separately; no generic defconfig or personal configuration is silently substituted.

```bash
git clone --no-checkout https://github.com/AsahiLinux/linux.git linux-hdmi-reconnect
git -C linux-hdmi-reconnect checkout --detach ce9f2eba72c061a50b2d790450e90af3439d8c24
bash patches/asahi/build-hdmi-reconnect.sh \
  "$PWD/linux-hdmi-reconnect" \
  /absolute/path/to/known-good-asahi.config \
  "$PWD/hdmi-reconnect-package"
```

Source must be a fresh, clean, disposable checkout and the output directory must not exist. The wrapper modifies only that source and creates the requested output. After a failed build, preserve logs and start with a fresh checkout rather than applying the patch again. The wrapper runs RED/GREEN gates, verifies patch applicability, sets the unique local version, prepares and checks the effective release, compiles all five affected translation units, then builds `Image modules dtbs` and packages the result. Its package recipe is for these explicitly built artifacts, not a standalone source-fetching PKGBUILD. Capture build output with your usual logging mechanism.

The package is `linux-asahi-hdmi-recover`, with release `7.1.13-1-1-ARCH-hdmi-recover`; it neither conflicts with nor replaces stock. The archive contains the release-scoped Image, modules, module metadata, `pkgbase`, and Apple DTBs in the stock flat `dtbs/` layout. `validate-package.py` checks compression, package identity, release isolation, required assets, and writes `validation.json` and `SHA256SUMS` in the output directory. Those reports describe the newly built package; `hardware_verified=false` is intentional because building a package cannot validate its boot or display behavior.

The exact functional patch and the equivalent machine-specific build/package sequence were exercised on the hardware below. The generalized wrapper added here has syntax/contract coverage but has **not** itself completed another full native build. A fresh build with this wrapper is an outstanding draft-PR gate. No prebuilt package is distributed by this change.

## Hardware evidence (limited, curated)

The test host reports **Apple MacBook Pro (16-inch, M2 Pro, 2023)**. It booted `7.1.13-1-1-ARCH-hdmi-recover`. The user confirmed a visible image on first connection and on **three complete unplug/replug cycles**, without restarting the compositor/session as a recovery step. The observed external mode was 2560×1440 at 75 Hz. This is one host and display configuration, not a general Apple Silicon compatibility claim.

The retained first-connect and all six disconnect/reconnect kernel captures were checked for `flip_done timed out`, `commit wait timed out`, `Oops:`, `BUG:`, and `Kernel panic`: zero matches in each cumulative capture through the third reconnect. The captures show disconnect callbacks and fresh power-on completion followed by mode completion on reconnect. A swallowed-swap message during the initial boot external-display power-off was already present in the baseline; it was not a new hotplug-test failure. Do not describe the entire boot as containing no swallowed swaps.

Sanitized third-reconnect sequence (monotonic seconds; host names, device addresses, pointers, and private paths omitted):

```text
809.207597  cb_hotplug() connected:1, valid_mode:0
809.221237  dcp_poweron() starting
809.221430  dcp_set_power_state_req returned, 10000 ms remaining
809.221521  set_digital_out_mode: 2560x1440 at 75 Hz [mode line summarized]
809.444019  set_digital_out_mode finished:8277
```

The pre-install build record reports successful compilation of `apple_drv.o`, `dcp.o`, `iomfb.o`, `iomfb_v12_3.o`, and `iomfb_v13_3.o`, followed by the full Image/modules/DTB build. Archive validation recorded 1,862 kernel modules and 110 Apple DTBs, successful zstd integrity, and Image/appledrm correspondence to built artifacts. These are historical validation results, not a new build on the PR preparation host.

- Exact included patch SHA-256: `dbf332ead80ad84d5fb681fe83fc92c89cb88e0d4e416142acbb80565aacedcf`
- Tested package SHA-256: `25f9294be649e9731363e122a685b5ee1fbebf0e5d1fdcc29788e66c671a1938`
- Tested Image SHA-256: `3cc1ce2a017910a6bf72d0efa1293808ff763faa3f2813046e1604aa405cf8aa`

Raw journals and machine-specific scripts are deliberately not committed because they contain pointer addresses and private paths. The original pre-install validation file says hardware was unverified at build time; the later physical observations above are separate evidence, not a retroactive change to that file.

## Safe installation and rollback validation

Installation is a separate, deliberate hardware-test action, not something these scripts perform. Before any installation, save work, keep remote recovery available, retain stock `linux-asahi`, and budget `/boot` space for both candidate Image and a complete initramfs. Never remove the running kernel or stock fallback to make room. Verify the package checksum and contents first.

After an authorized side-by-side installation, parse the candidate initramfs with `lsinitcpio`, not just a size/existence check. Resolve the exact stock and candidate entry IDs from the generated GRUB configuration. Preserve stock as the persistent saved default and select the candidate only for one boot (or use its explicit advanced-menu entry with save-default disabled). Do not assume menu index zero is stock after adding a kernel. Read back the GRUB environment and verify the actual running release after boot.

For rollback, select the verified stock advanced-menu entry and boot it; confirm `uname -r` reports stock, the graphical session works, and the saved default remains stock. Only then consider removing the inactive candidate package via the normal Omarchy package removal path. Never remove a candidate while it is running. On the tested host both stock and candidate packages remain installed and `saved_entry` names stock; **a post-fix reboot back to stock has not yet been performed**, so rollback bootability remains a required validation item rather than a claimed pass. Preparing this PR did not install packages, alter GRUB, or reboot the host.

## Remaining gates before promotion

- Perform an ordinary reboot back to stock and verify the graphical session and saved default.
- Complete a fresh native build/package using the generalized wrapper in this PR.
- Review and stress the gap between the flush generation check and asynchronous firmware swap submission; the generation check is not a lock around submission.
- Exercise shared synthetic-vblank work-item coalescing, real callback ordering/event ownership, and framebuffer lifetimes under rapid hotplug. The seam's synchronous mocks cannot establish these properties.
- Verify compositor liveness when a disconnect after atomic check causes a withheld swap; recovery depends on a subsequent commit permitting modesets.
- Expand coverage to additional monitors/modes, suspend/resume, repeated sessions, and other supported HDMI hardware/firmware. Both firmware translation units compiled; that is not hardware validation of both firmware versions.

Stop testing on a black reconnect, compositor freeze, firmware/DRM timeout, or crash; preserve the journal before another transition. Three successful cycles support opening this as an experimental draft, not a universal fix or a completed stress/rollback acceptance campaign.
