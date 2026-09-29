# Contributing

## Where a change belongs

| Your change | Where it goes |
| --- | --- |
| Mac settings, services and boot support that stay installed and run again at updates | Here, against `main` |
| A new Mac-only package | Here: open an issue first, then a pull request that meets the package contract |
| The Mac manual | Here, in the same pull request as the behaviour it describes |
| Release, acceptance or package-resolution tooling | Here, in `tools/` |
| The desktop, shell, bindings or shared helpers | [omacom/omarchy](https://github.com/omacom/omarchy). While [#13362](https://github.com/omacom/omarchy/pull/13362) is open, Apple Silicon desktop work that builds on it goes to `quattro-upstream` here. |
| Package recipes, signing and publication | [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs) |
| The macOS app, the Linux image or anything that runs once to install | [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer) |
| A hardware test report | [omarchy-m-testing.org](https://omarchy-m-testing.org) |

The line people most often get wrong is between `omarchy-mac-boot` and the installer. If it is on an installed Mac and runs again when the Mac updates, it belongs in `omarchy-mac-boot`. If it runs once to produce the system, it belongs in the installer.

## Pull requests

- Open them against `main`. Each needs an approval from someone other than its author, resolved review threads and passing CI.
- Keep a pull request to one change. A change to what the runtime reads from a package (the platform root, lifecycle entrypoints, setup commands) comes with an integration test in `test/integration/`.
- Boot-critical changes need cold-boot evidence from a test Mac before they are released.
- Anything Apple-specific must stay behind the platform detector, and a change to installed systems comes with its migration.

## Issues

Bugs go to [the issue tracker](https://github.com/omacom/omarchy-mac/issues), labelled `package:omarchy-mac`, `package:omarchy-mac-boot` or `desktop`. Installer bugs go to [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer/issues).

## Releases

- `omarchy-mac` uses semver in its `version` file. Bump it in the pull request that changes behaviour.
- `omarchy-mac-boot` is versioned by the UTC date of the commit its recipe pins; there is nothing to bump.
- A release is tagged per package, `omarchy-mac-v1.2.3` or `omarchy-mac-boot-v20261010`, and tags are never moved.
- Recipes in omacom/omarchy-pkgs pin full commit SHAs. `tools/release/mac-release` opens the pull request that moves them.
