# Omarchy Mac — Volunteer E2E Installation Checklist

Use this checklist for a **fresh, on-metal installation**, beginning in macOS and ending with a verified Omarchy desktop after a second login and cold boot. A successful `install.sh` exit alone is not an E2E pass.

Mark every applicable item **PASS**, **FAIL**, **BLOCKED**, or **SKIP**. Add evidence for failures and explain every skip. Stop at the first unsafe or unexplained storage/boot failure; collect evidence before retrying, repairing, or deleting the installation.

## 1. Test assignment

Complete this before starting so two volunteers do not unknowingly run the same case.

- [ ] Tester:
- [ ] Test ID / tracking issue:
- [ ] Date and timezone:
- [ ] Mac model and year:
- [ ] Apple model identifier (for example `MacBookAir10,1`):
- [ ] SoC: M1 / M1 Pro / M1 Max / M2 / M2 Pro / M2 Max:
- [ ] RAM / SSD:
- [ ] macOS version and build:
- [ ] Asahi Alarm image: **Minimal BTRFS** / Minimal ext4:
- [ ] Install path: **encrypted** / unencrypted:
- [ ] Keyboard layout:
- [ ] Omarchy repository and ref:
- [ ] Target source commit, if assigned:
- [ ] Network type: Wi-Fi / Ethernet:
- [ ] Important peripherals or external display:

### Coverage priority

1. **Primary:** fresh Asahi Alarm Minimal BTRFS → default encrypted guided install.
2. **Secondary:** fresh BTRFS → `--no-encrypt`.
3. **Special assignment only:** ext4 conversion, interruption/resume, unusual layouts, rollback, or recovery testing.

## 2. Safety and preparation

- [ ] macOS has a recent verified backup.
- [ ] Linux has at least 50 GB; 100 GB is preferred.
- [ ] The machine can be recovered from macOS if Linux fails to boot.
- [ ] Important local data has been removed from the test installation.
- [ ] The Mac is connected to power and reliable internet.
- [ ] The test will use the assigned repo/ref—not an unrecorded local modification.
- [ ] I will not run ad-hoc partition, encryption, initramfs, or bootloader repair commands before collecting failure evidence.
- [ ] I will never disable `speakersafetyd` or other speaker protection to make audio pass.

From macOS, record:

```bash
system_profiler SPHardwareDataType
sw_vers
diskutil list
```

Do not publish serial numbers. Redact them before attaching output.

## 3. Install and verify fresh Asahi Alarm

- [ ] Install the assigned Asahi Alarm image from macOS.
- [ ] Record the exact image/installer used and the allocated Linux size.
- [ ] Boot the untouched Asahi installation successfully before running Omarchy.
- [ ] Log in as `root` and connect using `nmtui`.
- [ ] Confirm display, built-in keyboard/trackpad or required USB input, Wi-Fi, DNS, and clock are working.
- [ ] Confirm this is genuinely fresh: Omarchy is not already installed and no earlier guided setup is resuming.

Capture the baseline:

```bash
uname -a
cat /etc/os-release
findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS --mountpoint /
findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS --mountpoint /boot
lsblk -f
df -h / /boot
free -h
```

If the fresh Asahi baseline already fails, report it separately. Do not count it as an Omarchy installer failure.

## 4. Start the guided installer

Use the exact command assigned by the test coordinator. For the current default branch:

```bash
curl -fsSL https://raw.githubusercontent.com/omacom/omarchy-mac/quattro/bin/omarchy-mac-setup | bash
```

- [ ] Record the command, repository, branch/ref, and start time.
- [ ] Confirm the installer identifies the expected encryption choice, hostname, username, and console keymap.
- [ ] Confirm the displayed plan matches the requested path.
- [ ] Default ARM-unavailable package prompt to **No**, unless this test specifically targets AUR availability.
- [ ] Photograph or transcribe warnings and the last visible line before every reboot.
- [ ] Record the duration of every stage and reboot.

Do not call a warning harmless merely because the installer continued. Record all skipped or unavailable packages.

## 5. Reboot checkpoints

### A. Boot-layout reboot — encrypted path only

- [ ] Apple boot → m1n1 → U-Boot → Linux boot menu completes normally.
- [ ] The setup resumes automatically on tty1; no permanent blank screen or blinking cursor.
- [ ] `/boot` has moved to a separate unencrypted partition.
- [ ] The installer advances to encryption instead of repeating the boot-layout step.

### B. Encryption reboot — encrypted path only

- [ ] The disk-passphrase prompt is visible and accepts input.
- [ ] The configured console keymap types the intended passphrase correctly.
- [ ] `cryptsetup reencrypt` progress is visible.
- [ ] Encryption finishes without an unexplained reboot, hang, or loop.
- [ ] On the next boot, the new passphrase unlocks the root filesystem.
- [ ] The setup resumes automatically and advances to Omarchy installation.

### C. Omarchy installation and final reboot

- [ ] Repository clone, package build/install, system setup, and user setup complete.
- [ ] Network loss or mirror errors are clearly reported rather than appearing as a hang.
- [ ] Required package failures do not get reported merely as optional skips.
- [ ] The final reboot reaches SDDM or the desktop according to the chosen login mode.
- [ ] The first graphical boot does not conflict with the tty1 setup service.
- [ ] The guided installer does not start again after completion.

## 6. First desktop login

- [ ] Login succeeds with the created user.
- [ ] The desktop renders correctly, including the notch-aware layout on MacBooks.
- [ ] First-run setup completes once and does not loop.
- [ ] Menu, launcher, terminal, browser, file manager, and settings open.
- [ ] Wi-Fi and DNS work.
- [ ] Built-in keyboard, trackpad, brightness keys, and keyboard backlight work where supported.
- [ ] Audio plays at modest volume with speaker protection active; headphones and microphone work if available.
- [ ] Lock and unlock work.
- [ ] Suspend/resume works once; Wi-Fi and input recover afterward.
- [ ] Change a theme and confirm the desktop remains usable.
- [ ] Record any missing application, notification error, visual defect, or obvious performance problem.

Note: the wiki's hardware matrix tracks one answer per feature (internal display, HDMI display, USB-C display, USB, Thunderbolt/docks, Wi-Fi, Bluetooth, speakers, headphones, microphone, HDMI audio, suspend, camera, Touch ID, keyboard, trackpad, GPU inference, Neural Engine). Running the evidence collector with `--interview` asks for each of these separately — WORKS / LIMITATION / BROKEN / UNKNOWN / n/a (not built in) — plus the peripheral model and connection you tested with. What a probe detected is never treated as proof a feature works; only your answer fills the matrix.

Collect the installed-system state:

```bash
omarchy version
printf '%s\n' "$OMARCHY_PATH"
readlink -f /usr/share/omarchy
pacman -Q omarchy omarchy-settings hyprland hyprtoolkit hyprland-guiutils aquamarine
pacman -Dk
systemctl --failed --no-pager
systemctl --user --failed --no-pager
omarchy-migrate --pending
omarchy-done check finalize-user
omarchy-done check first-run-user
swapon --show
findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS --mountpoint /
findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS --mountpoint /boot
```

Note: `omarchy-migrate --pending` exits **0 when migrations are pending** and **1 when none are pending**. Record its output; do not interpret the exit code like a normal success/failure result.

## 7. Persistence and security checks

- [ ] Log out and log in again: first-run prompts and notifications do not repeat.
- [ ] Reboot normally: disk unlock, login, desktop, Wi-Fi, audio protection, and required user services still work.
- [ ] Shut down fully, wait 15 seconds, then cold boot successfully.
- [ ] The created user can use `sudo` with their password.
- [ ] Temporary setup files, services, and passwordless privileges have been retired.
- [ ] Root access follows the selected `--keep-root-password` choice.
- [ ] SSH behavior matches the documented security policy; it is not silently exposed through the firewall.
- [ ] No required system or user unit has `LoadState=not-found`.

Useful checks:

```bash
systemctl is-enabled omarchy-mac-setup.service
test -e /etc/omarchy-mac-setup.conf; echo "setup_conf=$?"
test -e /etc/sudoers.d/01-omarchy-mac-setup; echo "setup_sudoers=$?"
systemctl --failed --no-pager
systemctl --user --failed --no-pager
journalctl -b -p warning --no-pager
journalctl --user -b -p warning --no-pager
```

For the `test` commands, exit status `1` is expected after cleanup because the temporary file should be absent.

## 8. If anything fails

Do **not** immediately rerun the installer, apply a suggested fix, or wipe Linux. First record:

- [ ] Exact stage, local time, expected result, and actual result.
- [ ] Last visible line and a photo/video of the screen.
- [ ] Whether the machine still responds to Caps Lock, SSH, or `Ctrl`+`Alt`+`F2/F3/F4`.
- [ ] Whether it reproduces after one normal retry; do not repeatedly force power off.
- [ ] Any hypothesis is clearly labelled as a hypothesis, separate from observations.

If a shell is reachable, collect:

```bash
/usr/local/bin/omarchy-mac-setup --status
systemctl status omarchy-mac-setup.service --no-pager
journalctl -u omarchy-mac-setup.service -b --no-pager
journalctl -b --no-pager
journalctl --list-boots
findmnt
lsblk -f
df -h / /boot
tail -n 200 /var/log/omarchy-install.log
tail -n 200 /var/log/pacman.log
```

Note: the current guided installer writes no `/var/log/omarchy-mac-setup.log` (its log variable is never redirected to a file), so do not treat that file's absence as a failure — the guided-setup output is in `journalctl -u omarchy-mac-setup.service`, captured above and by the evidence collector.

For an earlier failed boot, select the actual boot ID shown by `journalctl --list-boots`; do not assume `-1` is the failed attempt. Review logs before publishing and remove passwords, tokens, serial numbers, private hostnames, and other personal data.

## 9. Final result

Overall result: **PASS / FAIL / BLOCKED**

An E2E **PASS** requires all of the following:

- Fresh Asahi baseline worked.
- The assigned guided install path completed every stage.
- Automatic resume worked across every reboot.
- First desktop login and first-run completed.
- Second login, normal reboot, and cold boot succeeded.
- Required services, migrations, package state, storage layout, and security cleanup were verified.
- No required check was skipped.

## Report template

```text
Test ID:
Tester:
Date/timezone:
Mac model / Apple identifier / SoC / RAM:
macOS version:
Asahi image and filesystem:
Encryption and keymap:
Omarchy repo / ref / installed version:
Test command:

Fresh Asahi baseline: PASS / FAIL
Boot-layout stage: PASS / FAIL / SKIP
Encryption stage: PASS / FAIL / SKIP
Omarchy install stage: PASS / FAIL
First login: PASS / FAIL
Second login: PASS / FAIL
Normal reboot: PASS / FAIL
Cold boot: PASS / FAIL
Hardware smoke test: PASS / FAIL / SKIP
Security cleanup: PASS / FAIL

Overall: PASS / FAIL / BLOCKED
First failing checkpoint:
Expected:
Actual:
Reproduction steps:
Warnings / skipped packages:
Logs, photos, or video:
Related issue/PR:
Notes and clearly labelled hypotheses:
```

Keep evidence attached to the test ID or GitHub issue. “Installed successfully” without machine details, exact ref, reboot results, and logs is not a completed E2E report.
