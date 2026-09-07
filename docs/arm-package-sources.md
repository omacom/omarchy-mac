# ARM package sources

Apple Silicon installations use the regular Arch Linux ARM, Asahi Alarm, and Mac package repositories. The official `https://pkgs.omarchy.org/edge/$arch` repository has `Usage = Sync`, so it is refreshed but excluded from automatic package selection and upgrades.

The installer, system updater, and pacman channel refresh explicitly select `omarchy/hyprland`, `omarchy/hyprtoolkit`, and `omarchy/hyprland-guiutils` alongside a full system upgrade. Aquamarine and other dependencies resolve from the regular repositories. Dependency failures stop the transaction; no packages are ignored or dependencies bypassed.

The shared policy lives in `install/helpers/arm-package-sources.sh`. Package signatures are required and the existing Omarchy signing key is imported by its full fingerprint. Repository configuration preserves other repositories and mirror choices, saving `/etc/pacman.conf.bak` when it changes.

Use `omarchy update` for system upgrades. A bare `pacman -Syu` does not update the explicitly selected edge packages and can fail when their regular-repository dependencies change ABI. Edge is rolling; versions are resolved together at transaction time rather than pinned.

## Recovering an install that predates this policy

The policy travels inside the `omarchy` package, and both places that apply it — the installer and the update commands — are out of reach on a machine installed before it. The installer is over, and the update aborts in dependency resolution before the package carrying the helper can be replaced, so the machine cannot upgrade its way to the fix. Such a machine reports:

```
:: unable to satisfy dependency 'libaquamarine.so=13-64' required by hyprtoolkit
:: installing aquamarine (0.15.0-2) breaks dependency 'libaquamarine.so=13-64' required by hyprland
error: failed to prepare transaction (could not satisfy dependencies)
```

`fix-arm-packages.sh` in the repository root applies the same preparation from outside the package and then runs the selection, which is enough for `omarchy update` to work normally afterwards. It sources `install/helpers/arm-package-sources.sh` rather than restating it, taking the copy from its own checkout, `$OMARCHY_PATH`, or `/usr/share/omarchy`, and falling back to the published copy when an installed machine has none of them:

```bash
curl -fsSL https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/fix-arm-packages.sh | bash
```

The transaction runs as `sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu --noconfirm`, the same way `omarchy-update-system-pkgs` and `omarchy-refresh-pacman` do. The update guard hook aborts a `-Syu` that does not identify itself, and this is the update path arriving by another route rather than someone reaching past it. The transaction is noninteractive because the recommended pipe supplies the script itself on standard input.

`--dry-run` reports the configuration change and the transaction without applying either, and is the only mode that runs off Apple Silicon. Pass options after `bash -s --` when running the script through a pipe:

```bash
curl -fsSL https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/fix-arm-packages.sh | bash -s -- --dry-run
```

`--no-snapshot` skips the Snapper snapshot the script otherwise takes of the machine as found and can be passed the same way:

```bash
curl -fsSL https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/fix-arm-packages.sh | bash -s -- --no-snapshot
```

The transaction replaces the running compositor, so log out and back in before doing anything else.
