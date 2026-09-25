# omarchy-mac

Apple Silicon defaults and support services for Omarchy. Version: `0.1.0` (candidate). This add-on complements `omarchy` and `omarchy-settings`; it selects no kernel and contains no installer or repository trust configuration.

## Build and stage

This directory is self-contained. Copy it anywhere, run `./test/all`, then `./install /absolute/staging/root`. Staging requires Bash, coreutils and findutils; tests also use Python and systemd. Nothing is enabled or started by staging. The Arch recipe lives in `omarchy-mac/omarchy-pkgs-aarch64`, on `feature/omarchy-mac-package`, and pins a full collaboration-repository commit.

Runtime dependencies: `omarchy` (shared Apple hardware detector), Bash, coreutils, diffutils (cmp), grep, sed, gawk, systemd, pciutils, kmod, NetworkManager, iwd, Python, PipeWire, pipewire-pulse, libpulse (pactl), WirePlumber, and the protected Asahi speaker stack: asahi-audio (which pulls speakersafetyd), alsa-ucm-conf-asahi, rtkit and pipewire-alsa. The desktop audio leaf also installs that stack on machines set up before the recipe declared it. See `ORIGINS.md` for extraction attribution.

## Setup contract

Install the matching runtime, settings and add-on candidates in one pacman transaction. Their transferred commands and user unit must have only one owner. On Apple Silicon, include `install/omarchy-apple.packages` alongside the desktop base package list before calling `omarchy-apply-system`. The desktop checks the package is already present before its network hardware setup; offline setup never downloads it.

Run `omarchy-mac-setup-system` as root on the target hardware (inside its target chroot for offline provisioning). An optional absolute root argument supports staging against the same target hardware without a bus. It retires only exact generated Wi-Fi, module and service files, retaining a `.omarchy-mac-retired` backup. It enables resume recovery only for BCM4378/BCM4387 on Apple Silicon; BCM4388 and Intel/T2 are excluded. It is the only enabler of `speakersafetyd`, without which the kernel keeps the speakers muted: it applies the package's `80-omarchy-mac-audio.preset` once speakersafetyd is installed, so `/etc` presets, masks and later explicit disables win, and image builders that apply presets get the same result. A live run also restarts a speakersafetyd left dead by a start-limit. No NetworkManager restart or driver reload occurs during setup. The backend applies when NetworkManager next starts; notch changes apply when appledrm next loads.

Run `omarchy-mac-setup-user` as each target user with their HOME/XDG directories. It enables the vendor unit without a session bus. With a live bus it reloads the user manager, reports the effective unit and starts the mapper. Provisioning, first-run and the transition migration run setup; subsequent session starts only start the enabled unit, without reloading the user manager or repeating setup. The first desktop session does not depend on a bus existing during installation. Custom fragments, masks, activation links and headset or speaker policies are preserved; setup markers preserve explicit disables after initial setup. Exact per-user copies of mx-mac's speaker no-suspend policy retire in favour of the vendor one. User gain state remains in `omarchy/asahi-mic-gain.json` under XDG_STATE_HOME. The desktop saves that state before restarting audio.

Vendor defaults use NetworkManager's `/usr/lib/NetworkManager/conf.d`, systemd's `/usr/lib/systemd`, modprobe's `/usr/lib/modprobe.d`, and WirePlumber's `/usr/share/wireplumber/wireplumber.conf.d`. Same-name `/etc` or user fragments retain precedence. Setup reports effective live NetworkManager/module configuration and systemd fragments. Review those reports and any drop-ins when diagnosing overrides; custom policy is never normalized to the package default.

## Candidate qualification

The mocked behavioral tests cover Wi-Fi health, disabled radio, journal cursor/backstop recovery, unload/load failures and chipset gates; microphone gain/mute, device choices, missing endpoints, rollback and daemon loss; setup covers fresh/upgrade/repeated/interrupted operations, two users, first-session activation, masks and overrides, and the speakersafetyd preset with real systemctl. The desktop retains migration and audio restart integration coverage.

Before release promotion, record physical M1/M2 suspend/resume, speaker and microphone tests, effective configuration, package transaction, source/recipe revisions, and reboot evidence. Aurora needs separate evidence. A successful source test run or candidate build is not physical hardware qualification. Do not publish this candidate to the rolling feed automatically.
