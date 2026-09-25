# Apple Silicon Hardware Validation

Hardware qualification for Omarchy on Apple Silicon Macs. It is a promotion gate, not a test seam: a boot or package change reaches rc or stable only after it passes here on the M1 Pro (MacBookPro18,3, `apple,j314s`) and the M2 Max (Mac14,6, `apple,j416c`). VM acceptance must pass first so hardware failures are not confused with missing software, and VM success never substitutes for this checklist.

The scripts live in `tools/hardware/`; records of past runs live in `tools/hardware/evidence/`.

## Safety boundary

- Save active work and keep a local login available before network or suspend tests. Do not run suspend validation through an SSH-only session.
- Keep the Mac on external power for update checks, but test battery state reporting separately.
- Start with read-only checks. Do not install, remove, or update packages merely to make a check pass; record the observed failure first.
- Capture the current kernel, release, package-source, and boot-file hashes before any later update transaction. `tools/hardware/remote-check` prints them.
- Boot-critical changes need a cold boot (power off, power on), never only a warm reboot.

## Remote checks

`tools/hardware/remote-check HOST` runs the read-only checks from a controller over SSH: it copies `tools/hardware/mac-check` to the Mac, runs it through a login shell, removes it, and prints a report headed by the host, this checkout's revision and the time. On the Mac itself, run `tools/hardware/mac-check` directly. Either exits non-zero when a check fails.

Run it after every boot that follows a kernel or boot-file change, once the owner has logged in at the greeter (display and audio checks read the logged-in user's session and are skipped without one). Checks that need root go through `sudo -n` and are skipped without passwordless sudo.

| Check | Passes when |
| --- | --- |
| `kernel` | the running kernel's modules belong to the installed kernel package (`linux-aurora` on current installs, `linux-asahi` on legacy Asahi Macs), so no reboot is pending |
| `repos`, `kernel-repo` | `core`, `extra`, `alarm` and `asahi-alarm` are configured, and a configured repository carries the running kernel package |
| `boot-check` | `sudo omarchy-apple-silicon-boot-check` passes: kernel image, initramfs, the GRUB entry or Limine unified kernel image, and m1n1 stage 2 rebuilt and compared byte for byte, read-only. Skipped while an mx-mac kernel switch journal is open, since that boot check would record it |
| `boot-file` | the unified kernel image, `limine.conf` and `m1n1/boot.bin` on the ESP of a Limine Mac (the kernel image and `grub.cfg` on a GRUB Mac) exist; their SHA-256 hashes are printed for the record |
| `units` | `systemctl --failed` answers and lists nothing for the system and, when the user's manager is running, for the user too |
| `vendor-firmware` | `omarchy-vendor-firmware.service` finished in this boot |
| `speakersafetyd` | `speakersafetyd` is active |
| `displays` | Hyprland in the user's session reports at least one active display; compare the count and modes with the connected displays |
| `sound-cards`, `default-sink` | the kernel sees the sound cards in `/proc/asound/cards` and PipeWire's default sink is a real device, not its dummy output (on the test Macs, the model's speaker convolver unless headphones or a display take over) |
| `wifi`, `wifi-backend` | NetworkManager's Wi-Fi device is connected and NetworkManager uses iwd |
| `bluetooth` | `bluetoothctl show` reports `Powered: yes` |
| `snapshots` | `/.snapshots` is a btrfs subvolume |
| `migrations` | `omarchy-migrate --pending` lists nothing (a pending migration is a warning) |

It also prints identity lines for the record: model and device-tree compatibles, boot and Omarchy package versions, the mx-mac release marker and Aurora lane when present, the boot loader, and this boot's coredumps.

Known noise, not failures: the greeter's Hyprland (user `sddm`) can segfault when the owner logs in, and a crash popup can follow; Thunderbolt logs "PCIe-C … m1n1 handoff" when m1n1 did not hand over PCIe tunnelling. Compare both with an earlier boot (`coredumpctl list`, `journalctl -k -b -1`) before calling anything a regression.

## Checks at the Mac

These need the owner or a live session and stay manual.

### Desktop and graphics

- After a cold boot, confirm the boot menu and passphrase prompt (on an encrypted Mac), then that SDDM offers the remembered user and the Omarchy session, and complete an interactive login.
- Confirm the desktop shell, launcher, terminal, notifications, and screen lock render without software-rendering artifacts.
- Record the OpenGL and Vulkan renderer/device summaries. Apple GPU acceleration must be reported; `llvmpipe` or another software renderer is a failure.
- Exercise external displays and USB4 when available and record resolution, refresh rate, scaling, hotplug, and resume behavior.
- First-boot wizard on external displays: the kernel console clones every connected display at the smallest common mode, so a larger monitor shows the tty wizard with an unpainted band below it. That is fbcon, not the wizard; run first boot on the built-in panel or accept the band. It ends at the greeter.

### Networking

- Connect to a known Wi-Fi network, verify DNS and IPv4/IPv6 connectivity, then disconnect and reconnect once.
- Test Bluetooth discovery and one paired device if hardware is available.
- After suspend/resume, repeat Wi-Fi connectivity and DNS checks.

### Audio

- Speaker path end to end, as the logged-in user (SSH sessions have no seat): play a short, quiet 1 kHz tone with `pw-play` while `pw-record` captures the built-in microphones, then measure the 1 kHz energy (Goertzel) against a silent baseline recording. A clear rise is a pass.
- Play audio through the internal speakers and verify volume and mute controls.
- Record from the internal microphone and play the sample back.
- Test the headphone jack, Bluetooth audio, or HDMI audio when available; mark unavailable paths as not tested rather than passed.
- Repeat the internal speaker and microphone checks after suspend/resume.

### Power and suspend

- Record battery/AC state and available power profiles.
- From a local session, suspend once on AC and once on battery when safe.
- Verify wake input, display restoration, keyboard/trackpad, Wi-Fi, audio, brightness controls, and clock state after each resume.
- Inspect the current-boot journal for suspend, firmware, GPU, audio, and network errors and retain the relevant timestamps.

### Update safety

- Record the boot-file hashes from the remote check before a separately approved update test.
- If an update is approved, verify the signed release identity, cold boot, repeat this checklist, and explain every protected boot or package change.
- Snapshots: `snapper list` shows a numbered snapshot for the update just run. On a Limine Mac the Limine menu's `Snapshots` folder lists them and `omarchy-snapshot restore` runs `limine-snapper-restore`; the next boot's boot check verifies the unified kernel image on the ESP. On a GRUB Mac, `/boot/grub/grub-btrfs.cfg` lists them under the "Omarchy snapshots" submenu, and booting one gives a read-only snapshot under a tmpfs overlay with `/run/omarchy-snapshot-boot` naming the subvolume. The kernel on `/boot` stays, so only snapshots carrying its modules can be restored.

## Evidence record

For each run, record the date with its time zone, the Mac model and board, the kernel and boot packages, each check's pass/fail/not-tested state with the command or interaction used, and concise output. The remote check's report covers the automated part. Never mark a hardware path passed from VM evidence.

Records live in `tools/hardware/evidence/`, one directory each, text only. Bulky artifacts go to an immutable location and are pinned in `tools/hardware/evidence/artifacts.tsv`; `tools/hardware/evidence-verify --fetch` checks them. See [`tools/hardware/evidence/README.md`](../tools/hardware/evidence/README.md).

## Tests

`tools/hardware/test/all` runs the scripts against fixture systems and stub commands; it needs no Mac.
