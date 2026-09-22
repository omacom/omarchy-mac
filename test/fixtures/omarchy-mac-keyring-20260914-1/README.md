# Previous public keyring package fixture

These five package sources are copied byte-for-byte from local reviewed commit `61e7f31a3b47608325998cad5a1e8912f559e7cb`: `build-inputs/omarchy-mac-keyring/{PKGBUILD,omarchy-mac-keyring.install}` and `default/pacman/keyrings/{omarchy-mac.gpg,omarchy-mac-trusted,omarchy-mac-revoked}`. The package version is `20260914-1`. This provenance identifier is informational; running the test requires no Git history or remote access.

The fixture contains only public certificates, public trust metadata, and package source. It models the prior two-primary package for upgrade testing; it is not shipped as the current keyring, does not revoke keys, and does not assert this package was publicly released. `SHA256SUMS` binds the five original files. The native test verifies this manifest before building and checks that upgrading preserves preexisting client trust.
