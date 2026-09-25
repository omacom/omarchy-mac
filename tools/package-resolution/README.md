# Package resolution

Resolves each aarch64 platform's package set against the live pacman databases in a disposable pacman root and checks what a real transaction would do. Nothing is installed and the host's pacman state is never read or written.

```bash
tools/package-resolution/check                 # every platform under platforms/
tools/package-resolution/check generic-aarch64 # one platform
tools/package-resolution/test/check-test.sh    # the checks against synthetic repositories
```

It runs on any Arch Linux or Arch Linux ARM host or container, as a normal user, and needs `pacman`, `bsdtar` and `curl` (the self-test also needs `repo-add`). Mac hardware is never needed: `Architecture = aarch64` is forced, so an x86 Arch container resolves aarch64 databases the same way. CI runs both scripts in `.github/workflows/package-resolution.yml`, daily as well, since the databases move.

## Checks per platform

- **Repositories:** none of the platform's `forbidden_repos` is configured.
- **Closure:** every list entry and extra package resolves, and the whole set resolves in one transaction. Entries in `unpublished` are skipped with their reason and reported once they resolve.
- **Conflicts:** no closure package declares a conflict with another one. `pacman -Sp` skips this check, so it is computed from the databases, with versioned conflicts compared by `vercmp`.
- **Forbidden packages:** no closure package matches `forbidden_packages`.
- **linux provider:** reports what `pacman -S linux` selects and every package offering `linux`; fails when a forbidden package is selected. With `kernel` set, also reports the selection with that kernel installed.
- **Mac-only dependencies:** on platforms with `forbidden_packages`, nothing else in the configured repositories depends on a forbidden name.
- **File ownership:** no file in the closure (from the `.files` databases) has two owners.
- **Transitions:** for each `transitions` package, an installed equal version and a locally newer version are kept by `pacman -Su` and replaced by an explicit `pacman -S`; `-S --needed` skips the equal version.

## Platform fixtures

Each directory under `platforms/` holds a `pacman.conf` (only its repository order and servers are used) and a `platform` file sourced by `check`:

- `lists`: package lists, relative to the repository root
- `packages`: extra package names
- `forbidden_repos`, `forbidden_packages`: globs; `${mac_only[@]}` holds the names in `mac-only`
- `transitions`: packages to check equal-version and locally-newer upgrades for
- `kernel`: the platform kernel to report the `linux` provider with
- `unpublished`: `[name]="reason"` entries allowed to be absent

To check candidates before they are published, copy `platforms/`, add a repository stanza with a `file://` server pointing at a directory made with `repo-add` (it needs both the `.db` and `.files` databases), and pass the copy with `--platforms`. `--work DIR` keeps the databases, closures and file lists for inspection and reuses the downloads.
