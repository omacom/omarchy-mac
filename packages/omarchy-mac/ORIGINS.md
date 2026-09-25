# Source attribution

Extracted from Omarchy (MIT; see LICENSE), preserving the original helper and service names. Extraction baseline: `omacom/omarchy-mac` commit `350c46550b99688cdb5224408edd5870de2ca07b`.

- Wi-Fi recovery and behavioral tests: Scott Jones, `092ab7cf881742e790f58303b31cf7787802a8a9` (Reload brcmfmac after s2idle when Apple Silicon Wi-Fi wedges). Hardware restrictions and the journal cursor recovery algorithm are retained.

The network backend default follows Marcelo Alcantara's Apple Silicon integration in #9835, `4bc760378b5af60d730f52b7773c635e37331a81` and `2bd767f0e54a9138ada8b0e89b66e5080f2d1e33`. The legacy `wifi_backend.conf` fixture is the exact heredoc from the former commit. Package layout, setup, and migration tests are new work.

- Microphone mapper, user service, headset priority and behavioral tests: Scott Jones, `1d2f4af12cb4b65731bafa1305d1d5c9ac5507a8` (Map the Asahi mic array and install the protected audio stack). The mapper is extracted unchanged, including gain/mute persistence, device choice protection, graph rollback, and event-based supervision.
- Notch module default: Scott Jones, `cfe1d37e8f0fa27811938872325119e3eeca9354` (Floor the top bar at the Apple Silicon camera cutout), extracted from `install/hardware/apple/enable-notch.sh` at the baseline above; only the existing `appledrm show_notch=1` default moves to the vendor directory.
- Battery charge limit command and behavioral tests: Naeem Malik, `00a2d31019e4d5ea5a3e5e9cb45a75aa90d07ee2` (Add an Apple Silicon battery charge limit command, #497). The driver semantics and readback check are retained; the platform gate, saved limit and boot-time restore are new.
- Keyboard function-key mode: Marcelo Alcantara, maralcbr/omarchy-mx-mac `6f2248d4cc065f2cd88550ed414012151bc57622` (#266, `fnmode=3` on Apple Silicon), replacing Scott Jones's `fnmode=1` from `0022c4374d9f13dffd8b6415c095d1a5ae491d33` (Put media keys on the Apple Silicon top row without stealing x86 F-keys). The generated-line retirement, owed-rebuild handling and live switch follow both forks' migrations; leaving the kernel default in place and the setup command are new work.
