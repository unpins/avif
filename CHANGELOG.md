# Changelog

## [Unreleased]

## [1.4.1-2] - 2026-09-26

### Fixed

- The binary no longer carries `/nix/store/…-libxml2-…/etc/xml/catalog`, the
  path libxml2 looks in for the default XML catalog. It pointed inside the
  build directory of the machine that produced the artifact — a directory that
  exists nowhere else — and it was the only live store path left in the
  binary. It now points at `/etc/xml/catalog`, where a distribution puts it;
  `XML_CATALOG_FILES` still overrides.

### Changed

- Picking a program uses `--unpin-program=`, the same selector as the rest of
  the catalog: `avif --unpin-program=avifenc …`. The README still showed the
  positional form (`avif avifenc …`), which the binary answers with the list of
  programs and exit 1, and its `nix build` example ran `./result/bin/avifenc`,
  which is not a file — there is one binary, `bin/avif`. Installed commands are
  unaffected: `unpin install avif` still gives you plain `avifenc`, `avifdec`
  and `avifgainmaputil`.
