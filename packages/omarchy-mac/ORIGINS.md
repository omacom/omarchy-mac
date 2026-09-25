# Source attribution

Extracted from Omarchy (MIT; see LICENSE), preserving the original helper and service names. Extraction baseline: `omacom/omarchy-mac` commit `350c46550b99688cdb5224408edd5870de2ca07b`.

- Wi-Fi recovery and behavioral tests: Scott Jones, `092ab7cf881742e790f58303b31cf7787802a8a9` (Reload brcmfmac after s2idle when Apple Silicon Wi-Fi wedges). Hardware restrictions and the journal cursor recovery algorithm are retained.

The network backend default follows Marcelo Alcantara's Apple Silicon integration in #9835, `4bc760378b5af60d730f52b7773c635e37331a81` and `2bd767f0e54a9138ada8b0e89b66e5080f2d1e33`. The legacy `wifi_backend.conf` fixture is the exact heredoc from the former commit. Package layout, setup, and migration tests are new work.

- Microphone mapper, user service, headset priority and behavioral tests: Scott Jones, `1d2f4af12cb4b65731bafa1305d1d5c9ac5507a8` (Map the Asahi mic array and install the protected audio stack). The mapper is extracted unchanged, including gain/mute persistence, device choice protection, graph rollback, and event-based supervision.
- Notch module default: Scott Jones, `cfe1d37e8f0fa27811938872325119e3eeca9354` (Floor the top bar at the Apple Silicon camera cutout), extracted from `install/hardware/apple/enable-notch.sh` at the baseline above; only the existing `appledrm show_notch=1` default moves to the vendor directory.
- Greeter wait for the display controller: Marcelo Alcantara, maralcbr/omarchy-mx-mac `78b8ba410cf7d7b7749f0f66265a9ce438496db6` (Wait for the Apple display card before starting the greeter). The inline `ExecStartPre` moves to `lib/wait-for-display` behind the platform detector.
