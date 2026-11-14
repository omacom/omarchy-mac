![Omarchy 4 on an Apple Silicon MacBook: the top bar flowing around the display notch on a fresh install](hero.jpg)

# Omarchy Mac

Omarchy 4 on Apple Silicon, alongside macOS: Asahi Alarm + Omarchy, installed
in one command, full-disk encryption included.

[![License](https://img.shields.io/github/license/omacom/omarchy-mac)](LICENSE) [![Stars](https://img.shields.io/github/stars/omacom/omarchy-mac?style=social)](https://github.com/omacom/omarchy-mac/stargazers)

> [!IMPORTANT]
> **The Omarchy Mac team joined Omacom, and together we built the streamlined
> Apple Silicon version of Omarchy, first released with Omarchy 4.5.
> Omarchy for Apple Silicon is now an official Omacom solution.**
> Install it with the [Omarchy installer](https://github.com/omacom/omarchy-mac-installer), below.
> Its Mac packages and the [Mac manual](https://github.com/omacom/omarchy-mac-pkgs/tree/main/mac-manual)
> live in [omarchy-mac-pkgs](https://github.com/omacom/omarchy-mac-pkgs).
> Omarchy Mac is no longer maintained. Existing installs keep working but get no more
> updates. New installs should use Omarchy for Apple Silicon.

## Install Omarchy for Apple Silicon (recommended)

From macOS, install it with the Omarchy installer:

```bash
brew install omacom/mac/omarchy
```

Or download the installer from its [releases](https://github.com/omacom/omarchy-mac-installer/releases).
It sets up Omarchy for Apple Silicon next to macOS in one guided flow. See its
[supported Macs](https://github.com/omacom/omarchy-mac-installer#supported-macs) list.

What you get over this script install:

- **More Macs:** M3 MacBooks and iMacs, and the MacBook Neo, alongside M1 and M2.
- **Multiple monitors over USB-C.**
- **Fingerprint login** with Touch ID.
- **Snapshots you can boot:** pick an earlier snapshot from the Limine boot menu to roll back or restore.

### Moving from this setup

There is no in-place upgrade from the script install to Omarchy for Apple Silicon. To move:

1. **Back up** your home directory and anything else you want to keep, off the Mac.
2. **[Remove the old install](#removal-uninstall)** from macOS, so its disk space is free.
3. **Install Omarchy for Apple Silicon** as above.
4. **Restore** your files.

## Script install (no longer maintained)

Omarchy Mac is no longer maintained, and its scripts no longer start new
installs. Install Omarchy for Apple Silicon from macOS instead:

```bash
brew install omacom/mac/omarchy
```

Or see the [Mac manual](https://omarchy.org/manual/mac-support/).

Existing installs keep working but get no more updates. There is no in-place
upgrade to Omarchy for Apple Silicon: back up, remove the old install, install
Omarchy for Apple Silicon, then restore your files, as in
[Moving from this setup](#moving-from-this-setup).

---

## Troubleshooting

### SSH stopped working after the install

Asahi Alarm ships openssh enabled — the images are built for headless boards —
and Omarchy's install turns on a default-deny firewall that never opens port 22.
Nothing is uninstalled; the machine simply stops answering, which looks exactly
like sshd having been removed. Turn it back on deliberately:

```bash
omarchy-setup-security-sshd
```

It enables `sshd`, adds `ufw limit 22/tcp`, and offers to fetch your public keys
from `https://github.com/<user>.keys`. The same thing lives in the menu under
Setup → Security → SSH.

### The machine boots to `grub rescue>`

GRUB kept its modules and kernel on the root filesystem, and the root was
encrypted underneath it. See [docs/btrfs.md](docs/btrfs.md) — `/boot` has to be
the EFI partition before encrypting, which `omarchy-system-boot-to-esp`
arranges and `omarchy-system-btrfs-migrate` refuses to proceed without.

### Rolling back after a bad update

`omarchy snapshot restore` works on Apple Silicon. It offers snapper's
snapshots alongside `@fresh` — the system before Omarchy was installed — and
`@factory`, the installed system before it was yours, and says what you are
about to restore before doing anything. `/boot` is the EFI partition and sits
outside every snapshot; the tool warns when the restored root has no modules
for the running kernel.

### Mirrors are slow or failing

Run `bash fix-mirrors.sh` from the repository root and retry.

### The update stops on `libaquamarine.so` and cannot be repeated past it

An install made before the ARM package sources policy cannot upgrade its way to
it, because the update aborts before the package carrying it can be replaced.
Run the recovery and log out and back in afterwards:

```bash
curl -fsSL https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/fix-arm-packages.sh | bash
```

See [docs/arm-package-sources.md](docs/arm-package-sources.md) for what it changes and how to pass `--dry-run` or `--no-snapshot` to the piped script.

---

## Removal (uninstall)

There is no automatic uninstaller. Removal is done from macOS by deleting the
Linux partitions and growing the macOS container back over them. Follow the
[Asahi Linux partitioning cheatsheet](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)
exactly — it identifies which partitions are Asahi's and which are macOS's own,
and the wrong `diskutil` target can take macOS with it. If unsure, open an
issue.

---

## Support

Consider supporting the project: [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/malik2015no)

---

## More documentation

- The Omarchy manual — [manual/](manual/)
- Btrfs snapshots and disk encryption — [docs/btrfs.md](docs/btrfs.md)
- Upgrading from 3.x to Quattro — [docs/upgrade-to-quattro.md](docs/upgrade-to-quattro.md)

---

## External resources

- Asahi Linux (device support) — https://asahilinux.org/fedora/#device-support
- Asahi Alarm — https://asahi-alarm.org/
- Discord — https://discord.gg/KNQRk7dMzy

---

## Acknowledgements

Thanks to Asahi Linux and Asahi Alarm for enabling Linux on Apple Silicon, and to DHH for creating Omarchy.

If this guide helped you, please star the repository and share feedback in issues or discussions. If you enjoy Omarchy Mac, please share your experience on Twitter/X by tagging [@OmarchyMac](https://x.com/OmarchyMac).

---

## Omarchy Mac Contributors

Partial contributor list:

- tayowrld — https://github.com/tayowrld
- Owen Singh (itsOwen) — https://github.com/itsOwen
- Matthias Millhoff (embeatz) — https://github.com/embeatz
- George Dobreff — https://github.com/georgedobreff
- Luke Van — https://github.com/lukevanlukevan
- Wésley Guimarães — https://github.com/wesguima
- Vince Picone — https://github.com/vpicone
- Oleh Khomei — https://github.com/varyform
- Mike Deufel — https://github.com/MDeufel13
- Gwynspring — https://github.com/Gwynspring
- DinMon — https://github.com/DinMon
- Aslkhon — https://github.com/Aslkhon
- Marcelo Alcantara — https://github.com/maralcbr
- Scott Jones — https://github.com/scottjones
