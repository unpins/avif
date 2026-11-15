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
unpin avif --unpin-program=avifenc input.png output.avif
unpin avif --unpin-program=avifdec image.avif out.png
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
| `avifdec` | decode AVIF to PNG/JPEG/Y4M |
| `avifgainmaputil` | inspect / manipulate HDR gain maps |

## Man pages

`avifenc.1` and `avifdec.1` are embedded in the binary — read one with
`unpin man avif <program>`, e.g. `unpin man avif avifenc`. `avifgainmaputil`
has no upstream page; `avifgainmaputil --help` is its documentation.

## Build locally

```bash
nix build github:unpins/avif
./result/bin/avif --unpin-program=avifenc --version
./result/bin/avif --unpin-program=avifdec image.avif out.png
```

Or run directly:

```bash
nix run github:unpins/avif -- --unpin-program=avifenc input.png output.avif
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/avif/releases) page has standalone binaries for manual download.

## Build notes

- **Codecs:** AV1 encode via [aom](https://aomedia.googlesource.com/aom/), decode via [dav1d](https://code.videolan.org/videolan/dav1d). Reads/writes PNG, JPEG, and y4m.
- **`avifenc -a tune=vmaf`** needs `-a vmaf-model-path=<vmaf_v0.6.1.json>`: aom looks for the model in `/usr/local/share/model` otherwise.
- **Gain maps:** `avifgainmaputil` and `avifenc`'s gain-map-from-JPEG conversion are on (static `libxml2`).
- **Windows:** mingw.
- **Not shipped:** the gdk-pixbuf thumbnailer loader (dynamic pixbuf module, not a CLI).
- **Tests:** libavif's gtest suite runs as part of every build that can execute the result.
