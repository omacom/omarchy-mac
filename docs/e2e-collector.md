# E2E evidence collector (`bin/omarchy-mac-e2e-collect`)

Companion to [`omarchy-mac-e2e-volunteer-checklist.md`](omarchy-mac-e2e-volunteer-checklist.md). The checklist names what a volunteer must observe; this collector rides the guided install and gathers everything a machine can observe at the right time — fresh Asahi baseline *before* Omarchy, then installer, desktop, persistence, and a final root snapshot.

A point-in-time dump after Omarchy is already installed cannot reconstruct the pre-install mounts or the reboot checkpoints. This tool records those stages as they happen.

## Volunteer flow

On fresh Asahi Alarm, as **root**, after `nmtui`, before Omarchy setup:

```bash
curl -fsSL https://raw.githubusercontent.com/omacom/omarchy-mac/quattro/bin/omarchy-mac-e2e-collect | bash
```

If DNS cannot resolve GitHub:

```bash
curl -fsSL --doh-url https://1.1.1.1/dns-query https://raw.githubusercontent.com/omacom/omarchy-mac/quattro/bin/omarchy-mac-e2e-collect | bash
```

`--no-encrypt` assignment:

```bash
curl -fsSL https://raw.githubusercontent.com/omacom/omarchy-mac/quattro/bin/omarchy-mac-e2e-collect | bash -s -- --no-encrypt
```

Then:

1. Answer setup questions (hostname, user, password, encrypt unless `--no-encrypt`).
2. Type the disk passphrase when asked. Let it reboot.
3. Sign into Omarchy if you see a greeter (encrypted machines usually autologin).
4. Wait: desktop probes, one extra reboot, then a final root snapshot.
5. Share `~/omarchy-mac-e2e/REPORT.md`.

Do not curl again after reboots. The final snapshot is automatic on a new install from this script.

Already installed (backfill):

```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/omacom/omarchy-mac/quattro/bin/omarchy-mac-e2e-collect | bash -s -- final'
```

`sudo` must wrap the whole pipeline so bash is root.

Optional, from macOS before the Asahi installer:

```bash
curl -fsSL https://raw.githubusercontent.com/omacom/omarchy-mac/quattro/bin/omarchy-mac-e2e-collect | bash -s -- macos
```

## What is automatic vs human

| Step | Who | What happens |
|---|---|---|
| Backup, ≥50 GB Linux, power, internet | You | In macOS. Do not disable `speakersafetyd`. |
| Install Asahi Alarm Minimal BTRFS | You | Boot the untouched Asahi image. |
| `nmtui` as root | You | Network up. Do not start Omarchy yet. |
| `curl …e2e-collect \| bash` | You, once | Baseline + hooks + guided setup. |
| Setup questions / disk passphrase | You | ARM-unavailable packages stay No. |
| Setup reboots, desktop probes, persistence reboot | Automatic | |
| Final snapshot | Automatic on new installs; `sudo … final` if you already installed | Root checks (`ufw`, `nft`, `passwd -S root`, `journalctl --list-boots`) and a rebuilt report that keeps the Asahi baseline separate from the installed system. |
| Share | You | Attach `~/omarchy-mac-e2e/REPORT.md`. |

Hooks are `omarchy-mac-e2e-*` systemd units plus a drop-in on `omarchy-mac-setup.service`. They are removed after the final snapshot so they do not linger on the machine under test.

## Verdicts

The report fills PASS / FAIL / SKIP from evidence. It does **not** treat `omarchy version` as proof of first login.

- **First login PASS** requires a graphical session and a desktop smoke PASS (`hyprctl`, input, apps, network, `speakersafetyd` on aarch64).
- **Boot-layout / encryption** use `findmnt` (separate `/boot`, LUKS/mapper root), not installer status text.
- **Second login** stays SKIP: an extra software reboot is not a logout/login.
- **Cold boot** stays SKIP: a software reboot is not a 15s power-cut.
- **Overall PASS** only when baseline, install, first login, security cleanup, and (on the encrypted path) boot-layout plus encryption all PASS. Any FAIL wins. Remaining SKIPs keep overall at SKIP rather than inflating a pass.

Human-only checklist items (Apple boot chain visible, passphrase keymap, notch layout) are still the volunteer's to note if something looks wrong.

## Privacy

Every captured stream is redacted before it is written: serials, MACs, IPs, UUIDs, credential-shaped strings, this user's home path, and the live hostname/username (generic names like `alarm` / `root` are left alone). Share `REPORT.md`; the rest of `~/omarchy-mac-e2e/` is raw evidence.

Nothing is uploaded.

## If the install fails

Stop. Do not repair or wipe until evidence is saved.

```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/omacom/omarchy-mac/quattro/bin/omarchy-mac-e2e-collect | bash -s -- fail'
```

Then share `~/omarchy-mac-e2e/REPORT.md` if it exists, otherwise whatever is under `/var/lib/omarchy-mac-e2e/`.
