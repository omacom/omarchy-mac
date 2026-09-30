# Omarchy Mac packages

**Want Omarchy on your Mac?** Use the [Omarchy Installer](https://github.com/omacom/omarchy-mac-installer). This repository holds the packages it installs. It is not an installer, and it is not a copy of Omarchy.

This is the home of the Apple Silicon add-on packages for [Omarchy](https://github.com/omacom/omarchy), the tooling that releases and qualifies them, and the Mac manual. The desktop on a Mac is Omarchy's own; these packages add what the hardware needs on top of it.

## Packages

| Package | What it does | Version |
| --- | --- | --- |
| [`omarchy-mac`](omarchy-mac/) | Apple Silicon defaults and support services: the Wi-Fi backend and resume recovery, microphone mapping, speaker safety, the notch, keyboard and gestures, battery charge limits and hardware video decode | Semver, in `omarchy-mac/version` |
| [`omarchy-mac-boot`](omarchy-mac-boot/) | Boot support: the initramfs and vendor firmware, in-place encryption, first boot, Limine and U-Boot, update verification, factory reset and moving existing Macs onto these packages | The UTC date of the commit its recipe pins |

Both are built by recipes in [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs) and published to pkgs.omarchy.org for aarch64, on `edge` first. Each recipe pins an exact commit of this repository.

## What else is here

- [`mac-manual/`](mac-manual/): the user manual for Omarchy on a Mac, covering only what differs from [Omarchy's manual](https://omarchy.org/manual/).
- [`tools/`](tools/): release orchestration, VM and hardware acceptance, evidence checks and package resolution.
- [`test/integration/`](test/integration/): tests of the packages together, and against the Omarchy runtime they install into.

## The package contract

Every top-level package directory has:

- `install DESTDIR`, which stages the package into an absolute root and enables or starts nothing.
- `test/all`, which runs the package's own tests from a copy of the directory alone.
- `README.md` and `LICENSE`.
- A version: a `version` file, or one its recipe derives from the source.

A package never reads another package's tree or the runtime's source. Tests that need the runtime take a checkout of it from `OMARCHY_TEST_RUNTIME` and skip without one.

## Running the tests

```bash
omarchy-mac/test/all
omarchy-mac-boot/test/all
OMARCHY_TEST_RUNTIME=~/code/omarchy test/integration/all
```

CI runs all of them, with the runtime pinned to a reviewed commit.

## Contributing

Package changes come here as pull requests against `main`. Desktop, installer and packaging changes each have their own home: [CONTRIBUTING.md](CONTRIBUTING.md) says which.

## Transitional branches

Two branches remain from when this repository carried the whole Mac desktop. Each goes away once its job is done.

- **`quattro`** is what Macs on the Omarchy 4 fork update from today. A migration path will move those Macs onto official Omarchy with these packages; the branch is retired after that.
- **`quattro-upstream`** holds the Apple Silicon desktop work being merged into Omarchy through [omacom/omarchy#13362](https://github.com/omacom/omarchy/pull/13362). Desktop changes that build on it go there until the merge lands; then it is retired.

The Omarchy 3.8 tree that used to be `main` is kept, read-only, as `archive/omarchy-3.8`.

## Credits

Omarchy Mac was started by [Naeem Malik](https://github.com/malik-na) in September 2025, when he first brought Omarchy to Apple Silicon Macs, and it grew from there into the community project these packages come from. Thanks to everyone who has contributed since, to Asahi Linux and Asahi Alarm for making Linux on Apple Silicon possible, and to DHH for creating Omarchy.

## License

MIT, as Omarchy. See [LICENSE](LICENSE).
