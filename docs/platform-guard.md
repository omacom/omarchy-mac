# Platform packages and the pacman guard

Some packages belong on one kind of machine only: the Aurora kernel, m1n1 and U-Boot on an Apple Silicon Mac, firmware on a Snapdragon laptop. They share repositories with everything else. This page is the contract for how a package names its platform, and how pacman keeps it off other machines.

## Tagging contract

- A platform package declares `groups=('omarchy-platform-<platform>')` in its PKGBUILD. `<platform>` is the name `omarchy-hw-platform` prints for that hardware: `apple-silicon` or `qualcomm`.
- makepkg writes the group into `.PKGINFO`, repo-add copies it into the repository database as `%GROUPS%`, and pacman keeps it in the local database. The tag is readable wherever the package is: `pacman -Sg omarchy-platform-apple-silicon` lists the Apple packages the configured repositories offer, and `pacman -Qg omarchy-platform-apple-silicon` the installed ones.
- A package for several platforms carries one group per platform. A package for every machine carries none. The CPU stays in `arch=()`; a tag names hardware. A tag naming no platform, such as a typo, is refused on every machine.
- A tag follows the package name, not the repository: pacman hands the guard names only, so a name tagged in any synced database is refused on other platforms whichever repository supplies it. Tag only platform-only names (`linux-aurora`, `m1n1-aurora`, `uboot-asahi`, `omarchy-mac`, `omarchy-mac-boot`). Never tag a shared name, such as a carried `aquamarine`: every repository's copy would then be refused elsewhere. This is the plan's scoping rule: Apple packages have Apple-only names, no generic provides, and nothing generic depends on them.
- Packages from repositories Omarchy does not build, such as asahi-alarm's `asahi-audio`, `speakersafetyd` and `linux-asahi`, carry no tag. They stay off other machines because only the Apple profile configures those repositories.
- The group also makes the set installable by name (`pacman -S omarchy-platform-apple-silicon`); the guard applies to that like any other transaction.

### Adopting it in a recipe

Each Mac recipe on omacom/omarchy-pkgs adds one line beside `arch=('aarch64')`:

```bash
groups=('omarchy-platform-apple-silicon')
```

That covers `linux-aurora` (top level, so both `linux-aurora` and `linux-aurora-headers`), `omarchy-mac`, `m1n1-aurora`, `uboot-asahi` and, when its recipe lands, `omarchy-mac-boot`. Qualcomm packages add `groups=('omarchy-platform-qualcomm')`.

## The guard

- `omarchy-settings` installs `default/libalpm/hooks/00-omarchy-platform-guard.hook` to `/usr/share/libalpm/hooks/`, the guard it runs, `default/libalpm/scripts/omarchy-platform-guard`, to `/usr/share/libalpm/scripts/`, and the detector the guard asks, `omarchy-hw-platform`, to `/usr/bin/`. Shipping all three in one package means the hook never points at a missing script, and the guard can tell the platform before the `omarchy` runtime is installed.
- The hook runs before every transaction that installs or upgrades a package, with the transaction's package names on stdin, dependencies included. It is `AbortOnFail`: a refusal stops the transaction before anything changes.
- The guard reads tags from every synced database in `/var/lib/pacman/sync`, not through `pacman.conf`, so a transaction run with another `--config`, as pacstrap and image builders do, is still checked. A transaction without a tagged package passes without asking which machine this is.
- With a tagged package in the transaction, the guard works out the platform (below) and refuses the transaction when a package's tags do not include it, naming each such package and its platforms. When the platform cannot be told, because the detector reports contradictory identity or the manifest is invalid, tagged packages are refused and untagged ones still install.
- A database it cannot read is reported and skipped, so a broken or stale database never wedges pacman.
- Not covered: `pacman -U` of a tagged package file whose name no synced database carries, and a transaction run with a `--dbpath` other than the root's `/var/lib/pacman`.
- No environment variable changes what the guard does: as root it ignores exported shell functions and restarts in an empty environment before reading anything. To turn it off on purpose, mask it: `ln -s /dev/null /etc/pacman.d/hooks/00-omarchy-platform-guard.hook`. An Apple image under VM acceptance needs this, since a VM's device tree is not a Mac's, and so updates of its Apple packages are refused.

## Which platform

- **A booted system**, where the transaction root is PID 1's root: `omarchy-hw-platform`, so the hardware decides. Environment overrides and any image-target manifest in the root are ignored. The hardware also decides when PID 1 is visible but its root cannot be compared.
- **An image build**, where the transaction runs in a chroot on a build host (arch-chroot, or `pacman --root`) or in a root without `/proc`: the image-target manifest at `/var/lib/omarchy/image-target` in the image's root decides. Without a manifest the hardware decides, which is right for an installer running on the target machine, and which refuses Apple packages on a build host that is not a Mac; the refusal says so. A container or nspawn build whose PID 1 runs in the image root counts as a booted system, so its build steps run in a chroot.
- **The manifest** is a regular file owned by root and writable only by root. It sets `platform=` once, to `apple-silicon`, `qualcomm`, `generic-aarch64` or `generic`. Comments and other `key=value` lines are ignored. Any other manifest refuses tagged packages.
- `omarchy-platform-guard --platform` prints the platform the guard checks against.

An image builder writes the manifest before the first transaction that installs platform packages:

```bash
install -Dm644 /dev/stdin "$root/var/lib/omarchy/image-target" <<<'platform=apple-silicon'
```

A booted image ignores it, so leaving it in place does no harm.

## Order on a fresh install

A hook installed in a transaction does not check that transaction: pacman loads pre-transaction hooks before it extracts any package. So:

1. The installer installs `omarchy-settings` in a transaction before any platform package. The generic ISO does: its early bootstrap transaction installs the settings package before the runtime and `omarchy-base.packages`, and its first pacstrap holds no platform package.
2. Platform packages come in a later transaction: `install/omarchy-apple.packages`, the Apple kernel and the boot chain included, so none of them may be in a first pacstrap. An Apple image builder must install the settings package first, write the image-target manifest, then install the Apple set. The mx-mac era builders do not: they pacstrap the Aurora kernel, m1n1 and U-Boot first and write no manifest, so they cannot build an image with tagged packages until they follow this order.
3. `omarchy-apply-hardware` starts with `install/hardware/platform-guard.sh`. It fails when the hook or its script is missing, then runs `omarchy-platform-guard --installed`, which checks every installed package against the platform, so anything an installer placed without the guard is caught. System setup before it installs no packages. `test/shell.d/platform-guard-test.sh` checks this order.

## Services and entry points

The guard keeps platform packages off other machines; their services and commands still re-check the platform when they activate. Every `omarchy-mac` command asks `omarchy-hw-apple-silicon` before acting, and every unit carries an `ExecCondition=`. `packages/omarchy-mac/test/platform-test.sh` holds each command and unit to that. Its configuration fragments for NetworkManager, modprobe and WirePlumber have no activation step to check from; they rely on the guard.

## Packaging

The `omarchy-settings` recipe installs the three files, and links the detector into `/usr/share/omarchy/bin/` where the Apple predicate and the CLI router look for it; the `omarchy` recipe leaves the detector out of its `bin/` loop. Until the upstream source the recipes build carries these files, the lines are conditional:

```bash
if [[ -f bin/omarchy-hw-platform ]]; then
  install -Dm755 bin/omarchy-hw-platform "$pkgdir/usr/bin/omarchy-hw-platform"
  install -d "$pkgdir/usr/share/omarchy/bin"
  ln -s /usr/bin/omarchy-hw-platform "$pkgdir/usr/share/omarchy/bin/omarchy-hw-platform"
fi
if [[ -f default/libalpm/hooks/00-omarchy-platform-guard.hook ]]; then
  install -Dm644 default/libalpm/hooks/00-omarchy-platform-guard.hook "$pkgdir/usr/share/libalpm/hooks/00-omarchy-platform-guard.hook"
  install -Dm755 default/libalpm/scripts/omarchy-platform-guard "$pkgdir/usr/share/libalpm/scripts/omarchy-platform-guard"
fi
```

`omarchy` depends on the `omarchy-settings` of its own version, so the two upgrade in one transaction and the detector moves between them there. `test/shell.d/config-test.sh` checks both recipes.
