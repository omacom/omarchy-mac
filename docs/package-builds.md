# Mac package builds

`build-packages.sh` builds four packages on aarch64: the keyring, JetBrains font, settings and runtime. The recipes are exported from the full commit in `packaging/omarchy-pkgs.commit`; `packaging/mac-profile.patch` is checked and applied to that disposable export. A moving upstream branch or a dirty recipe checkout cannot silently change the build. A missing commit or a patch that no longer applies stops the build.

`OMARCHY_PKGS_PATH` may point to an existing recipe repository or its `pkgbuilds/` directory. The builder reads Git objects without checking out a branch, pulling or editing that repository. Without an explicit path it first checks the known local recipe directories, then fetches the pinned commit into a bare cache under `${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-build/recipes.git`. Source archives use a separate cache under `omarchy-build/sources`.

## Build without installing anything

Install the required build tools beforehand. An ordinary build checks `makedepends` from the actual recipes with `pacman -T` and fails if any are missing. It does not invoke sudo. The installer explicitly selects `OMARCHY_BUILD_DEPS=install` so its existing installation flow can install missing build tools. Neither mode installs the resulting package archives; that is a separate installer step.

Use a directory on disk for `TMPDIR` on a machine with limited RAM, because `makepkg` stages source and payload copies and `/tmp` may be a small tmpfs:

```bash
mkdir -p "$HOME/.cache/omarchy-build/tmp"
TMPDIR="$HOME/.cache/omarchy-build/tmp" ./build-packages.sh
```

Packages build serially. `OMARCHY_PACKAGE_OUTPUT` selects the output directory; it is a handoff directory whose previous package archives are removed before a new build. `OMARCHY_PACKAGE_SRCDEST` selects the archive cache. `OMARCHY_PKGREL` optionally overrides the release number of both runtime and settings, retaining the existing Mac hotfix workflow. Source checksums remain enabled.

## The reviewed Mac profile

The pinned upstream recipe already distinguishes x86 and ARM dependencies. The overlay adds Snapper and zram-generator to the ARM runtime dependencies, delivers the keyboard ambient-light service to its systemd vendor location, and preserves the fork's existing memory configuration: the vendor zram drop-in, app.slice and oomd settings, sysctl values and zswap tmpfiles rule. It does not restore the obsolete `/etc/systemd/zram-generator.conf`; local `/etc` overrides retain their usual priority. Memory policy changes are separate work.

The ARM boot payload explicitly allows `omarchy_hooks.conf` and `thunderbolt_module.conf`. The first contains the fork's Asahi hook handling; the second checks the target kernel with `modinfo` before adding its module. They retain pacman backup protection. Limine configuration, dependencies and the Limine snapshot notifier remain excluded. This profile applies to the supported Asahi M1/M2 models without a board allowlist; device-specific service behavior remains in the existing runtime capability checks.

The Apple settings scriptlet preserves upstream's distribution identity, PAM, NSS and Plymouth choices. It additionally publishes the shipped Bash startup file to `/etc/skel/.bashrc`, which is owned by the Bash package and therefore cannot also be owned by omarchy-settings. The installer replays skel into its newly created user. Package upgrades refresh this skel template, including local edits to that template, but the scriptlet does not overwrite existing user homes. Upstream's existing CUPS scriptlet handling remains in place.

## Provenance and versions

`build-provenance.txt` records the runtime Git commit and whether the checkout was modified, its `version` file, the recipe repository and full commit, the overlay hash, architecture, and every archive's actual `.PKGINFO` name/version and SHA-256. Runtime and settings archive versions, including pkgrel, must match. Build both from the same checkout without editing it during the build; development builds allow a dirty checkout and report that fact rather than claiming its contents are reproduced by the commit alone.

The source version and package version are distinct under the upstream local-source convention: `OMARCHY_SRC` supplies this checkout while the recipe retains its release metadata. At this pin the recipes say `4.0.2-1`, while the reviewed checkout's `version` says `4.0.0.alpha`. The profile does not invent a source release or rewrite that file. The provenance makes this distinction explicit; publishing release archives still needs an intentional source/version decision.

## Updating the recipe pin

Review the upstream recipe diff from the current pin, including scriptlets and architecture-specific dependencies and removals. Update the full commit and adapt the small overlay to the new recipe contract. Run the focused checks, then build archives and inspect `.PKGINFO`, package payloads and `build-provenance.txt` before installation or publication:

```bash
bash test/shell.d/package-recipes-test.sh
bash test/shell.d/install-mac-test.sh
TMPDIR="$HOME/.cache/omarchy-build/tmp" ./test/package-profile
```

`test/package-profile` may fetch the pinned recipes if no local object source is available. It evaluates the real recipes' metadata and `package()` functions into disposable directories, checks delivered files against this source, and exercises the real Apple scriptlet with its absolute paths redirected into fixtures. It never installs a package or runs a scriptlet against the host. It covers both thunderbolt-module outcomes and representative M1/M2 Apple compatible strings, not physical hardware behavior, boot success, live service activation or a full pacman transaction. Native archive builds provide the additional makepkg checks and `.PKGINFO` evidence.
