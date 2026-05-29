# avif

Standalone build of the [libavif](https://github.com/AOMediaCodec/libavif) command-line tools — `avifenc` (encode) and `avifdec` (decode) for the AVIF image format.

[![CI](https://github.com/unpins/avif/actions/workflows/avif.yml/badge.svg)](https://github.com/unpins/avif/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Installation

Install with [unpin](https://github.com/unpins/unpin):

```bash
unpin avif
```

This drops both `avifenc` and `avifdec` on your PATH (they are argv[0] shims into one multicall binary).

## Build locally

```bash
nix build github:unpins/avif
./result/bin/avifenc --version
./result/bin/avifdec image.avif out.png
```

Or run directly:

```bash
nix run github:unpins/avif -- avifenc input.png output.avif
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/avif/releases) page has standalone binaries for manual download.

## Build notes

- **Multicall:** one binary at `bin/avif` carries both tools; `avifenc` / `avifdec` are dispatched by `argv[0]`. Invoke the bare binary as `avif <tool> [args]` too.
- **Codecs:** AV1 encode via [aom](https://aomedia.googlesource.com/aom/), decode via [dav1d](https://code.videolan.org/videolan/dav1d). Reads/writes PNG, JPEG, and y4m.
- **Windows:** `mingw` cross, single `.exe`, no companion DLLs.
- **macOS:** static `.a` codec chain linked in; only system frameworks/libSystem stay dynamic.

The codec chain (`libavif`, `libyuv`, `aom`, `dav1d`, …) is the same one wired up for [chafa](https://github.com/unpins/chafa) in [`nix-lib/native-overlay`](https://github.com/unpins/nix-lib/tree/main/native-overlay); here the apps are turned back on and post-linked into the multicall binary.
