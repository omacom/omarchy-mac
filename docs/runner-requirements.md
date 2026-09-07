# Install VM runner requirements

The **Install VM** workflow uses GitHub's disposable `ubuntu-24.04-arm` runners for every pull request, pushes to `quattro`, manual runs, and the nightly schedule. No self-hosted runner registration is needed. The workflow installs `systemd-container`, `curl`, `gnupg`, CA certificates, `tar`, and `gzip`; removes unused hosted-image toolchains; and fails early unless at least 20 GiB is free.

The Arch Linux ARM guest runs under `systemd-nspawn`, sharing the host's kernel without nested KVM. A generic ARM64 kernel with Landlock support is sufficient for installer and userspace validation. The harness explicitly allows the three Landlock system calls through nspawn's default syscall filter, so current pacman can enforce its download sandbox even with an older host systemd. Host diagnostics report the kernel configuration and active security modules when readable; package sandboxing remains enabled. Apple boot, Asahi kernel behavior, and Apple GPU support still require hardware testing.

## Run locally on a disposable ARM64 host

The harness needs an aarch64 Linux host, `systemd-nspawn`, `curl`, `gpg`, `sha256sum`, tar/gzip, root or passwordless sudo, and outbound access to the Arch Linux ARM rootfs and keyserver, package mirrors, and AUR. Allow at least 20 GiB free for the rootfs, packages, build files, and prepared snapshot.

From the checkout to test:

```bash
export OMARCHY_INSTALL_VM_WORK="/var/tmp/omarchy-install-$(date +%s)"
export OMARCHY_INSTALL_VM_CACHE="$(mktemp -d)"
export OMARCHY_INSTALL_VM_PACKAGE_SOURCES=1
export OMARCHY_INSTALL_VM_IDEMPOTENCY=1
sudo --preserve-env=HOME,OMARCHY_INSTALL_VM_WORK,OMARCHY_INSTALL_VM_CACHE,OMARCHY_INSTALL_VM_PACKAGE_SOURCES,OMARCHY_INSTALL_VM_IDEMPOTENCY bash ./test/vm/run-selective-edge
```

The harness removes its guest root on exit and keeps logs under `$OMARCHY_INSTALL_VM_WORK/logs`. Local cache and logs remain for inspection; hosted jobs discard the machine after uploading logs. GitHub keeps each run's log artifact for seven days.

`test/vm/setup-github-runner` remains a legacy helper for registering an Apple Silicon runner for trusted manual hardware workflows. Install VM no longer selects those runners. Never route untrusted fork PRs onto a persistent desktop runner.
