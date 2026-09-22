# The engine's FFmpeg build

`Libavutil`, `Libavcodec`, `Libavformat` and `Libswresample` are FFmpeg
**n8.1.2** — libavutil 60.26.102, libavcodec 62.28.102, libavformat 62.12.102,
libswresample 6.3.102 — built by `scripts/build-ffmpeg.py` from one configure,
so the four share one `config.h` and cannot drift from each other. The network
stack is compiled out (`--disable-network --disable-protocols`, with only the
`file` and `data` protocols libavformat itself still needs re-enabled), and
all four are **LGPL-2.1-or-later**.

## Why

Until 1.0.2 only libavformat was built here; libavcodec, libavutil and
libswresample were MPVKit 1.0.0's prebuilt binaries, fetched at resolve time.
Two problems with that.

**Licence.** MPVKit configures FFmpeg with `--enable-version3`, because its
GnuTLS requires it, so its libraries were effectively LGPL-3.0, statically
linked into a binary Apple signs. LGPL-3.0's Installation Information
requirement sits badly with App Store distribution. Building here without
GnuTLS drops the election, and `check_license()` fails the build if
`CONFIG_GPL`, `CONFIG_NONFREE` or `CONFIG_VERSION3` is ever anything but 0 in
any of the four.

**Availability.** A binary target pinned by URL stops resolving the day its
release is deleted, and then nobody can build the package from source — not a
contributor, and not a consumer relying on the source being buildable for
their LGPL obligations. Nothing here is fetched at resolve time any more.

The same two problems are why lcms2 and uavs3d, which libavcodec links, are
built here too (`scripts/build-lcms2.sh`, `scripts/build-uavs3d.sh`). dav1d
already was, for a reason of its own: its assembly.

Certificate trust is also simpler for it: with no TLS stack inside FFmpeg, it
means one thing — Apple's system trust store, evaluated once, in Swift.

## How HTTP reaches the server now

`FFmpegNetworkTransport` fetches and feeds media over `URLSession`;
libavformat itself never opens a socket.

## Rebuild and verify

Requires Xcode, Python 3.12+ and pkg-config, and the `Libdav1d`, `lcms2` and
`Libuavs3d` artifacts already in `Artifacts/`: configure links libavcodec
against them, through pkg-config files the script writes to point at this
repository rather than at anything installed on the machine. All compiler
roles use Apple Clang, including FFmpeg's host tools. A full build of every
platform takes about five minutes.

```sh
python3 scripts/build-ffmpeg.py --work /private/tmp/lagoon-ffmpeg-build
python3 scripts/build-ffmpeg.py --verify-only Artifacts/Lib{avutil,avcodec,avformat,swresample}.xcframework
```

The only thing the script downloads is FFmpeg's own checksum-pinned source
tarball. It builds iOS and tvOS arm64 devices, arm64/x86_64 simulators, and
arm64/x86_64 macOS; deployment targets are iOS/tvOS 26 and macOS 14. x86_64 is
built without nasm assembly, the same trade `build-dav1d.sh` makes and for the
same reason. `--groups` and `--output` allow development builds; commit all
five platform groups.

`verify()` re-derives none of this from trust. For every artifact it checks
file checksums against `BUILD.json`, and for every architecture that
`config.h` reports LGPL-2.1-or-later and `CONFIG_NETWORK 0`, that
`FFMPEG_CONFIGURATION` contains `--disable-network` and not
`--enable-version3`, that no http/https/tls/tcp/udp protocol symbol is
defined, and that nothing references GnuTLS, GMP, nettle, Vulkan,
libplacebo, shaderc or libass. libavformat must also report
`CONFIG_HLS_DEMUXER 1`, and libavcodec the `libdav1d` and `libuavs3d`
decoders and lcms2. `BUILD.json` records the source URL and hash, the patch
hashes, the dependency versions, the Xcode version, the full configure flags
per platform and architecture, and every file's checksum. Absolute toolchain
paths are recorded for provenance; byte-identical output across Xcode
versions is not promised.

Source: https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.1.2

Source SHA-256: `9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7`.

FFmpeg's `COPYING.LGPLv2.1` and `LICENSE.md` accompany each artifact.

## What changed against MPVKit's build

Checked when the switch was made, against MPVKit 1.0.0's libraries and the
previous libavformat — symbols on the iOS device slice, output in the tvOS
simulator:

- **Codecs, formats, parsers and bitstream filters are identical.** The
  selection list below is MPVKit's, and every `ff_*_decoder`, `_encoder`,
  `_parser`, `_bsf`, `_demuxer` and `_muxer` symbol matches, except the four
  Vulkan hwaccels.
- **The public API is identical**, except `av_vk_get_optional_*_extensions`.
  The engine names neither.
- **Output is bit-identical.** A set of fixtures — AV1 10-bit through
  libdav1d, HEVC Main10, VP9 10-bit, H.264 progressive and interlaced,
  MPEG-2, AAC, AC-3, E-AC-3, DTS, TrueHD, FLAC, Opus and MP3 with their
  libswresample conversions, and SRT, ASS and mov_text subtitles — decoded to
  the same SHA-256 on the old and new libraries in the tvOS simulator.
- **Not built:** Vulkan, libplacebo, shaderc, libass and its font stack,
  libavfilter, libswscale and libavdevice. MPVKit carries them for mpv's
  renderer; the engine links none of them.
- **The assembler is newer.** Xcode 27 assembles FFmpeg's aarch64 dotprod
  and i8mm kernels, which MPVKit's toolchain skipped, so libavcodec carries
  them and selects them at runtime on chips that have the instructions. That
  cannot change output, as the fixtures show, but it can change speed, so it
  is covered by the Apple TV frame-loss comparison.
- **Only public headers are vended.** MPVKit also shipped a few of FFmpeg's
  internal headers (`libavutil/internal.h` and friends, `libavcodec/mathops.h`,
  `libavformat/os_support.h`). The engine uses none of them. `config.h` and
  `config_components.h` are vended in all four, because `verify()` reads them.
- `av_version_info()` reads `8.1.2` rather than `n8.1.2`: FFmpeg takes it from
  git when it can, and this builds from the release tarball.

## The codec selection list

`scripts/ffmpeg-selections.txt` holds the `--enable-muxer=` /
`--enable-demuxer=` / `--enable-encoder=` / `--enable-decoder=` flags, and
the four `--disable-*s` lines that scope them. It is committed, not derived.
It came from MPVKit 1.0.0's build, parsed out of `FFMPEG_CONFIGURATION` in its
`config.h`, and ends with the two external decoders, `libdav1d` and
`libuavs3d`. Adding a codec there is not enough on its own to play it; see
`docs/codec-support.md`.

## Patches

One patch is applied to the source before configure:
`Patches/0001-hls-scheme-without-network-protocols.patch`. hls.c guards every
child URL by asking libavformat for a registered protocol matching its
scheme, and without a network stack no protocol matches an http(s) URL, so
the demuxer refused every playlist and segment with "Invalid data found when
processing input" before `io_open` was consulted. The patch lets `open_url`
classify `http:`/`https:` (also behind `crypto+`/`data+`) from the URL text
and hand the open to the application's `io_open`. `BUILD.json` records the
patch hash and `--verify-only` fails if it changes.

## Retired: the GnuTLS/Apple-trust patch

Earlier builds carried `Patches/0001-apple-tls-verification.patch`, which
taught FFmpeg's GnuTLS backend to verify its peer chain against Apple system
trust (GnuTLS itself does not load system roots on iOS/tvOS). That patch,
and the GnuTLS/GMP/nettle/hogweed dependency it verified, were retired along
with the rest of libavformat's network stack: there is no TLS backend left
in this artifact to patch. Certificate trust for HTTP now lives entirely in
the engine, alongside `FFmpegNetworkTransport`.
