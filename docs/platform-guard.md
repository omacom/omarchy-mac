# Platform packages and the pacman guard

Some packages belong on one kind of machine only: the Aurora kernel, m1n1 and U-Boot on an Apple Silicon Mac, firmware on a Snapdragon laptop. They share repositories with everything else. This page is the contract for how a package names its platform, and how pacman keeps it off other machines.

## Tagging contract

- A platform package declares `groups=('omarchy-platform-<platform>')` in its PKGBUILD. `<platform>` is the name `omarchy-hw-platform` prints for that hardware: `apple-silicon` or `qualcomm`.
- makepkg writes the group into `.PKGINFO`, repo-add copies it into the repository database as `%GROUPS%`, and pacman keeps it in the local database. The tag is readable wherever the package is: `pacman -Sg omarchy-platform-apple-silicon` lists the Apple packages the configured repositories offer, and `pacman -Qg omarchy-platform-apple-silicon` the installed ones.
- A package for several platforms carries one group per platform. A package for every machine carries none. The CPU stays in `arch=()`; a tag names hardware.
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

- `omarchy-settings` installs `default/libalpm/hooks/00-omarchy-platform-guard.hook` to `/usr/share/libalpm/hooks/` and the guard it runs, `default/libalpm/scripts/omarchy-platform-guard`, to `/usr/share/libalpm/scripts/`. Shipping both in one package means the hook never points at a missing script.
- The hook runs before every transaction that installs or upgrades a package, with the transaction's package names on stdin, dependencies included. It is `AbortOnFail`: a refusal stops the transaction before anything changes.
- The guard reads tags from every synced database in `/var/lib/pacman/sync`, not through `pacman.conf`, so a transaction run with another `--config`, as pacstrap and image builders do, is still checked. A transaction without a tagged package passes without asking which machine this is.
- With a tagged package in the transaction, the guard works out the platform (below) and refuses the transaction when a package's tags do not include it, naming each such package and its platforms. When the platform cannot be told, because the detector reports contradictory identity or is not installed, tagged packages are refused and untagged ones still install.
- A database it cannot read is reported and skipped, so a broken or stale database never wedges pacman.
- Not covered: `pacman -U` of a tagged package file whose name no synced database carries, and a transaction whose `--dbpath` lies outside its root.
- No environment variable changes what the guard does. To turn it off on purpose, mask it, as VM acceptance does for an Apple image in a VM whose device tree is not a Mac's: `ln -s /dev/null /etc/pacman.d/hooks/00-omarchy-platform-guard.hook`.

## Which platform

- **A booted system**, where the transaction root is PID 1's root: `omarchy-hw-platform`, so the hardware decides. Environment overrides and any image-target manifest in the root are ignored.
- **An image build**, where the transaction runs in a chroot on a build host or in a root without `/proc`: the image-target manifest at `/var/lib/omarchy/image-target` in the image's root decides. Without a manifest the hardware decides, which is right for an installer running on the target machine, and which refuses Apple packages on a build host that is not a Mac.
- **The manifest** is a regular file owned by root and writable only by root. It sets `platform=` once, to `apple-silicon`, `qualcomm`, `generic-aarch64` or `generic`. Comments and other `key=value` lines are ignored. Any other manifest refuses tagged packages.

An image builder writes the manifest before the first transaction that installs platform packages:

```bash
install -Dm644 /dev/stdin "$root/var/lib/omarchy/image-target" <<<'platform=apple-silicon'
```

A booted image ignores it, so leaving it in place does no harm.

## Order on a fresh install

A hook installed in a transaction does not check that transaction: pacman loads pre-transaction hooks before it extracts any package. So:

1. The installer installs `omarchy-settings` in a transaction before any platform package. The ISO does: its early bootstrap transaction installs the settings package before the runtime and `omarchy-base.packages`.
2. Platform packages come in a later transaction: `install/omarchy-apple.packages`, the kernel and the boot chain. The Apple image builder installs the settings package first, writes the image-target manifest, then installs the Apple set.
3. `omarchy-apply-hardware` starts with `install/hardware/platform-guard.sh`. It fails when the hook or its script is missing, then runs `omarchy-platform-guard --installed`, which checks every installed package against the platform, so anything an installer placed without the guard is caught. System setup before it installs no packages. `test/shell.d/platform-guard-test.sh` checks this order.

## Packaging

The `omarchy-settings` recipe installs the two files. Until the upstream source it builds carries them, the lines are conditional:

```bash
if [[ -f default/libalpm/hooks/00-omarchy-platform-guard.hook ]]; then
  install -Dm644 default/libalpm/hooks/00-omarchy-platform-guard.hook "$pkgdir/usr/share/libalpm/hooks/00-omarchy-platform-guard.hook"
  install -Dm755 default/libalpm/scripts/omarchy-platform-guard "$pkgdir/usr/share/libalpm/scripts/omarchy-platform-guard"
fi
```

`test/shell.d/config-test.sh` checks that the recipe installs both.
