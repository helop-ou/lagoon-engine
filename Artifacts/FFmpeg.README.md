# The engine's FFmpeg build

`Libavutil`, `Libavcodec`, `Libavformat` and `Libswresample` are FFmpeg
**n8.1.2** (libavutil 60.26.102, libavcodec 62.28.102, libavformat 62.12.102,
libswresample 6.3.102), built by `scripts/build-ffmpeg.py` from one configure,
so all four share one `config.h`. The network stack is compiled out
(`--disable-network --disable-protocols`, re-enabling only the `file` and
`data` protocols libavformat needs). All four are **LGPL-2.1-or-later**.

## Why

Until 1.0.2, only libavformat was built here; the other three were MPVKit
1.0.0's prebuilt binaries, fetched at resolve time.

- **Licence.** MPVKit configures with `--enable-version3` for GnuTLS, which
  made its libraries effectively LGPL-3.0, statically linked into an
  Apple-signed binary. LGPL-3.0's Installation Information requirement sits
  badly with App Store distribution. Built here without GnuTLS, there is no
  version-3 election, and `check_license()` fails the build if `CONFIG_GPL`,
  `CONFIG_NONFREE` or `CONFIG_VERSION3` is ever non-zero in any of the four.
- **Availability.** A binary pinned by URL stops resolving when its release is
  deleted, and then nobody can build from source, including a consumer
  relying on that for their LGPL obligations. Nothing is fetched at resolve
  time now.

lcms2 and uavs3d, which libavcodec links, are built here for the same reasons
(`scripts/build-lcms2.sh`, `scripts/build-uavs3d.sh`). dav1d is built here for
its assembly.

With no TLS inside FFmpeg, certificate trust means one thing: Apple's system
trust store, evaluated once, in Swift. `FFmpegNetworkTransport` fetches media
over `URLSession`; libavformat never opens a socket.

## Rebuild and verify

Requires Xcode, Python 3.12+, pkg-config, and the `Libdav1d`, `lcms2` and
`Libuavs3d` artifacts already in `Artifacts/`. Configure links libavcodec
against them through pkg-config files the script writes, pointing at this
repository, not at anything installed on the machine. All compiler roles,
FFmpeg's host tools included, use Apple Clang. A full build of every platform
takes about five minutes.

```sh
python3 scripts/build-ffmpeg.py --work /private/tmp/lagoon-ffmpeg-build
python3 scripts/build-ffmpeg.py --verify-only Artifacts/Lib{avutil,avcodec,avformat,swresample}.xcframework
```

- The script downloads only FFmpeg's checksum-pinned source tarball.
- It builds iOS and tvOS arm64 devices, arm64/x86_64 simulators, and
  arm64/x86_64 macOS. Deployment targets: iOS/tvOS 26, macOS 14.
- x86_64 is built without nasm assembly, the same trade `build-dav1d.sh`
  makes.
- `--groups` and `--output` allow development builds; commit all five
  platform groups.

`verify()` trusts nothing. For every artifact it checks file checksums against
`BUILD.json`, and for every architecture that:

- `config.h` reports LGPL-2.1-or-later and `CONFIG_NETWORK 0`;
- `FFMPEG_CONFIGURATION` contains `--disable-network` and not
  `--enable-version3`;
- no http/https/tls/tcp/udp protocol symbol is defined;
- nothing references GnuTLS, GMP, nettle, Vulkan, libplacebo, shaderc or
  libass;
- libavformat reports `CONFIG_HLS_DEMUXER 1`, and libavcodec the `libdav1d`
  and `libuavs3d` decoders and lcms2.

`BUILD.json` records the source URL and hash, the patch hashes, the dependency
versions, the Xcode version, the full configure flags per platform and
architecture, and every file's checksum. Absolute toolchain paths are
recorded for provenance; byte-identical output across Xcode versions is not
promised.

Source: https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.1.2

Source SHA-256: `9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7`.

FFmpeg's `COPYING.LGPLv2.1` and `LICENSE.md` accompany each artifact.

Every GitHub release carries the complete corresponding source as
`lagoon-engine-<version>-ffmpeg-8.1.2-source.tar.gz`: upstream's tarball,
`changes.diff` with the patch, and this revision's build script and
`BUILD.json` records. `scripts/ffmpeg-source-bundle.sh` makes it, and
`scripts/publish-release.sh` attaches it.

libavcodec includes the Independent JPEG Group's DCT code (`jrevdct.c`,
`jfdctint_template.c`, `jfdctfst.c`), and FFmpeg's `LICENSE.md` asks that an
executable's documentation credit it: "this software is based in part on the
work of the Independent JPEG Group".

## What changed against MPVKit's build

Checked at the switch, against MPVKit 1.0.0's libraries and the previous
libavformat (symbols on the iOS device slice, output in the tvOS simulator):

- **Codecs, formats, parsers and bitstream filters are identical.** Every
  `ff_*_decoder`, `_encoder`, `_parser`, `_bsf`, `_demuxer` and `_muxer`
  symbol matches, except the four Vulkan hwaccels.
- **The public API is identical**, except `av_vk_get_optional_*_extensions`,
  which the engine does not use.
- **Output is bit-identical.** Fixtures (AV1 10-bit through libdav1d, HEVC
  Main10, VP9 10-bit, H.264 progressive and interlaced, MPEG-2, AAC, AC-3,
  E-AC-3, DTS, TrueHD, FLAC, Opus and MP3 with their libswresample
  conversions, and SRT, ASS and mov_text subtitles) decoded to the same
  SHA-256 on old and new libraries.
- **Not built:** Vulkan, libplacebo, shaderc, libass and its font stack,
  libavfilter, libswscale and libavdevice. MPVKit carries them for mpv's
  renderer; the engine links none.
- **The assembler is newer.** Xcode 27 assembles FFmpeg's aarch64 dotprod and
  i8mm kernels, which MPVKit's toolchain skipped; libavcodec selects them at
  runtime where the chip has them. Output is unchanged; speed is covered by
  the Apple TV frame-loss comparison.
- **Only public headers are vended.** MPVKit also shipped some internal
  headers (`libavutil/internal.h` and friends, `libavcodec/mathops.h`,
  `libavformat/os_support.h`), which the engine does not use. `config.h` and
  `config_components.h` are vended in all four, because `verify()` reads them.
- `av_version_info()` reads `8.1.2`, not `n8.1.2`: FFmpeg takes it from git
  when it can, and this builds from the release tarball.

## The codec selection list

`scripts/ffmpeg-selections.txt` holds the `--enable-muxer=` /
`--enable-demuxer=` / `--enable-encoder=` / `--enable-decoder=` flags and the
four `--disable-*s` lines that scope them. It is committed, not derived. It
came from MPVKit 1.0.0's `FFMPEG_CONFIGURATION` and ends with the two external
decoders, `libdav1d` and `libuavs3d`. Adding a codec there does not by itself
make it play; see `docs/codec-support.md`.

## Patches

One patch is applied before configure:
`Patches/0001-hls-scheme-without-network-protocols.patch`. hls.c checks every
child URL for a registered protocol matching its scheme, and without a network
stack none matches http(s), so every playlist and segment failed with "Invalid
data found when processing input" before `io_open` was asked. The patch lets
`open_url` classify `http:`/`https:` (also behind `crypto+`/`data+`) from the
URL text and hand the open to the application's `io_open`. `BUILD.json`
records the patch hash, and `--verify-only` fails if it changes.

## Retired: the GnuTLS/Apple-trust patch

Earlier builds carried `Patches/0001-apple-tls-verification.patch`, which made
FFmpeg's GnuTLS backend verify peers against Apple system trust. It went with
GnuTLS, GMP, nettle, hogweed and the rest of the network stack. Certificate
trust now lives entirely in the engine, beside `FFmpegNetworkTransport`.
