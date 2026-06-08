# avif

The [libavif](https://github.com/AOMediaCodec/libavif) command-line programs for the AVIF image format, as a single self-contained binary built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/avif/actions/workflows/avif.yml/badge.svg)](https://github.com/unpins/avif/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install avif`.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin avif avifenc input.png output.avif
unpin avif avifdec image.avif out.png
```

To install the programs onto your PATH:

```bash
unpin install avif
```

`unpin install avif` creates the `avifenc`, `avifdec`, and `avifgainmaputil` commands.

## Programs

| command | what it does |
| --- | --- |
| `avifenc` | encode to AVIF |
| `avifdec` | decode AVIF to PNG/Y4M |
| `avifgainmaputil` | inspect / manipulate HDR gain maps |

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

- **Multicall:** one binary at `bin/avif` carries all three tools; `avifenc` / `avifdec` / `avifgainmaputil` are dispatched by `argv[0]`. Invoke the bare binary as `avif <tool> [args]` too.
- **Codecs:** AV1 encode via [aom](https://aomedia.googlesource.com/aom/), decode via [dav1d](https://code.videolan.org/videolan/dav1d). Reads/writes PNG, JPEG, and y4m. The codec chain (`libavif`, `libyuv`, `aom`, `dav1d`, …) is the same one [chafa](https://github.com/unpins/chafa) wires up; here the apps are turned back on and post-linked into the multicall binary.
- **Gain maps:** `avifgainmaputil` and `avifenc`'s gain-map-from-JPEG conversion are on (static `libxml2`).
- **Windows:** `mingw` cross, single `.exe`, no companion DLLs.
- **macOS:** static `.a` codec chain linked in; only `libSystem` stays dynamic.
- **Not shipped:** the gdk-pixbuf thumbnailer loader (dynamic pixbuf module, not a CLI). No upstream man pages.
- **Tests:** libavif's gtest suite isn't built (`AVIF_BUILD_TESTS=OFF`) — it exercises the library, which the same codec chain already proves via chafa's decode path; the CLIs are covered by the `avifenc --version` smoke.
