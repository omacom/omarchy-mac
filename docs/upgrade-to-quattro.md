# Upgrading Omarchy Mac 3.x to Quattro (Omarchy 4)

> Omarchy Mac is now part of Omarchy for Apple Silicon, so `omarchy-upgrade-to-quattro-mac` no longer upgrades a 3.x install. It prints where to go and exits without changing anything. Install the official Omarchy for Apple Silicon from macOS with `brew install omacom/mac/omarchy`, or see the [Mac manual](https://omarchy.org/manual/mac-support/). The rest of this page describes what the upgrade did, for machines that already ran it.

Quattro is the Omarchy 4 generation: the Waybar/Walker/Mako desktop is replaced
by a single Quickshell-based shell, Hyprland configuration moves to Lua, and
updates flow through `omarchy update` with per-user migrations.

On regular x86 machines, Omarchy 4 is installed from pacman packages and lives
at `/usr/share/omarchy`. **Omarchy Mac published no Omarchy packages for Apple
Silicon**, so a Mac got there by a different route depending on how it was
installed:

- **A fresh install** built those same packages locally. `install.sh` ran
  `build-packages.sh` and installed the result with `pacman -U`, so
  `/usr/share/omarchy` is ordinary package content, exactly as on x86. The
  checkout at `~/.local/share/omarchy` was the build source and installer, not
  the runtime. `install.sh` now refuses new installs.
- **The upgrade**, from a 3.x machine, left it running from that checkout with
  `/usr/share/omarchy` symlinked at it, because 3.x already lived there and the
  upgrade did not rebuild the machine around packages.

On a fresh install `OMARCHY_PATH` is `/usr/share/omarchy`. After the upgrade it
is the checkout, with `/usr/share/omarchy` symlinked to it.
`ls -ld /usr/share/omarchy` says which you have.

The upgrade wired the checkout into the places the packaged install would
occupy, installed the new desktop stack from Arch Linux ARM and the AUR, and
removed the old one.

## Read this first

- **Never run `omarchy-upgrade-to-quattro` on a Mac.** That command is the
  upstream x86 upgrade: it rewrites `/etc/pacman.d/mirrorlist` to point at
  Omarchy's x86_64 package mirrors, which do not serve aarch64. Running it
  breaks pacman for the whole system. The command ships in this repo because we
  track upstream. The Mac upgrade, `omarchy-upgrade-to-quattro-mac`, is retired
  (see below).
- **The upgrade was one-way.** There is no supported downgrade to 3.x.
- The upgrade replaced your Hyprland configuration. 3.x used `hyprland.conf`;
  Quattro is configured in Lua. Your old files were moved aside, not deleted.

## What the script did

1. Backs up `~/.config` to `~/.config.omarchy3.<timestamp>.bak`.
2. Switches `~/.local/share/omarchy` to the `quattro` branch (it refuses to run
   if the checkout has uncommitted changes, and refuses to continue unless the
   checked-out tree is a Quattro one).
3. Installs the Quattro package set from `install/omarchy-base.packages` with
   yay, skipping the few upstream packages that are x86-only, and installs
   `wf-recorder` — Apple GPUs cannot run gpu-screen-recorder, so screen
   recording uses wf-recorder on the Mac.
4. Wires the checkout into the system: `/usr/share/omarchy` symlink,
   `OMARCHY_PATH` in `/etc/omarchy.conf`, the login/session environment files,
   and `/usr/bin/omarchy-*` symlinks (Omarchy's systemd units start commands by
   that path).
5. Replaces the 3.x line in `~/.bashrc` with Quattro's two-line bootstrap.
6. Moves `~/.config/hypr` to a `.bak` and copies in the Quattro defaults.
7. Runs `omarchy-setup-system --upgrade`, `omarchy-finalize-user`, and
   `omarchy-migrate`.
8. Removes the retired Waybar/Walker/Mako/SwayOSD desktop stack and switches
   networking from iwd to NetworkManager.

The script now refuses to run, so it can no longer repair a machine. The
troubleshooting steps below fix the pieces by hand.

## After the upgrade

- [ ] The bar appears at the top of the screen (that is the new Quickshell shell).
- [ ] `omarchy-shell lock status` reports `passwordPam: true`. If not, run
      `sudo omarchy-setup-lock`.
- [ ] Wi-Fi is now managed by NetworkManager; reconnect with
      `nmcli device wifi connect <ssid> --ask` if it did not carry over.
- [ ] Pick your theme again with `omarchy theme set <name>`.
- [ ] `omarchy update` updates system and AUR packages and runs migrations. The
      checkout is frozen, so it no longer pulls new commits.

## Troubleshooting

- **New terminals print "No such file or directory" mentioning
  `/usr/share/omarchy`** — the symlink or `/etc/omarchy.conf` is missing;
  recreate them:
  `sudo ln -sfn ~/.local/share/omarchy /usr/share/omarchy` and
  `echo "export OMARCHY_PATH=\"$HOME/.local/share/omarchy\"" | sudo tee /etc/omarchy.conf`
- **The lock screen does nothing** — run `sudo omarchy-setup-lock` and check
  `omarchy-shell lock status` again.
- **A systemd unit fails with status 203/EXEC** — a `/usr/bin/omarchy-*`
  symlink is missing; recreate the symlinks:
  `for c in ~/.local/share/omarchy/bin/omarchy-*; do sudo ln -sf "$c" /usr/bin/; done`
- **No Wi-Fi after reboot** — NetworkManager is now in charge: reconnect with
  `nmcli device wifi connect <ssid> --ask`.
