# Upgrading Omarchy Mac 3.x to Quattro (Omarchy 4)

Quattro is the Omarchy 4 generation: the Waybar/Walker/Mako desktop is replaced
by a single Quickshell-based shell, Hyprland configuration moves to Lua, and
updates flow through `omarchy update` with per-user migrations.

On regular x86 machines, Omarchy 4 is installed from pacman packages and lives
at `/usr/share/omarchy`. **No Omarchy packages are published for Apple
Silicon**, so a Mac gets there by a different route depending on how it was
installed:

- **A fresh install** builds those same packages locally — `install.sh` runs
  `build-packages.sh` and `pacman -U`s the result — so `/usr/share/omarchy` is
  ordinary package content, exactly as on x86. The checkout at
  `~/.local/share/omarchy` is the build source and installer, not the runtime.
- **This upgrade**, from a 3.x machine, keeps running from that checkout and
  symlinks `/usr/share/omarchy` at it, because 3.x already lived there and the
  upgrade does not rebuild the machine around packages.

Either way `OMARCHY_PATH` is `/usr/share/omarchy`; the difference is whether it
is a directory or a symlink. `ls -ld /usr/share/omarchy` says which you have.

The upgrade wires the checkout into the places the packaged install would
occupy, installs the new desktop stack from Arch Linux ARM and the AUR, and
retires the old one.

## Read this first

- **Never run `omarchy-upgrade-to-quattro` on a Mac.** That command is the
  upstream x86 upgrade: it rewrites `/etc/pacman.d/mirrorlist` to point at
  Omarchy's x86_64 package mirrors, which do not serve aarch64. Running it
  breaks pacman for the whole system. The command ships in this repo because we
  track upstream — the Mac upgrade is `omarchy-upgrade-to-quattro-mac` below.
- **The upgrade is one-way.** There is no supported downgrade to 3.x.
- **Back up first.** At minimum, know that your macOS side is safe and copy
  anything irreplaceable off the Linux side. The script also backs up
  `~/.config` and your Hyprland config before touching them.
- Your Hyprland configuration is replaced. 3.x used `hyprland.conf`; Quattro is
  configured in Lua. Your old files are moved aside, not deleted, but expect to
  redo personal keybindings and monitor tweaks in the new format.

## Run the upgrade

Omarchy Mac is no longer maintained, so `omarchy-upgrade-to-quattro-mac` no longer upgrades a 3.x install. It prints where to go and exits without changing anything. Install the official Omarchy for Apple Silicon from macOS with `brew install omacom/mac/omarchy`, or see the [Mac manual](https://omarchy.org/manual/mac-support/). The rest of this page describes what the upgrade did, for machines that already ran it.

## What the script does

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

Re-running the script after a failure is safe — every step either skips work
that is already done or redoes it harmlessly.

## After the upgrade

- [ ] The bar appears at the top of the screen (that is the new Quickshell shell).
- [ ] `omarchy-shell lock status` reports `passwordPam: true`. If not, run
      `sudo omarchy-setup-lock`.
- [ ] Wi-Fi is now managed by NetworkManager; reconnect with
      `nmcli device wifi connect <ssid> --ask` if it did not carry over.
- [ ] Pick your theme again with `omarchy theme set <name>`.
- [ ] `omarchy update` now updates the checkout, runs migrations, and restarts
      the shell — that is the normal update path from here on.

## Troubleshooting

- **New terminals print "No such file or directory" mentioning
  `/usr/share/omarchy`** — the symlink or `/etc/omarchy.conf` is missing;
  re-run the script.
- **The lock screen does nothing** — run `sudo omarchy-setup-lock` and check
  `omarchy-shell lock status` again.
- **A systemd unit fails with status 203/EXEC** — a `/usr/bin/omarchy-*`
  symlink is missing (usually after a new command is added); re-run the script
  or recreate the symlinks:
  `for c in ~/.local/share/omarchy/bin/omarchy-*; do sudo ln -sf "$c" /usr/bin/; done`
- **No Wi-Fi after reboot** — NetworkManager is now in charge: reconnect with
  `nmcli device wifi connect <ssid> --ask`.
