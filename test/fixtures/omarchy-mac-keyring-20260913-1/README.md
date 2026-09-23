# Shipped quattro keyring package fixture

These five package sources are copied byte-for-byte from `origin/quattro` commit `04862a02c556b5c4305b2ea3430e9d2cfaab66c4`: `build-inputs/omarchy-mac-keyring/{PKGBUILD,omarchy-mac-keyring.install}` and `default/pacman/keyrings/{omarchy-mac.gpg,omarchy-mac-trusted,omarchy-mac-revoked}`. The package version is `20260913-1`. This provenance identifier is informational; running the test requires no Git history or remote access.

The fixture contains only public certificates, public trust metadata, and package source. It models the old-primary-only package shipped on the quattro baseline, does not revoke keys, and is the real predecessor for upgrade testing. `SHA256SUMS` binds the five original files. The native test verifies this manifest before building and checks that upgrading adds the new primary without disturbing existing old or unrelated client trust.
