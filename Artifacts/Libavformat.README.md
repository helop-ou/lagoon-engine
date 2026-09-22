# Lagoon's libavformat build

`Libavformat.xcframework` is FFmpeg **n8.1.2 / libavformat 62.12.102**, built
by `scripts/build-ffmpeg-format.py` with networking compiled out
(`--disable-network --disable-protocols`, with only the `file` and `data`
protocols libavformat itself still needs re-enabled). Only libavformat is
replaced; the codec, utility and resampler pins remain unchanged.

## Why

Two things upstream's networked libavformat carried that Lagoon no longer
wants: a bundled TLS stack it had to trust independently of the system, and
a license bump. GnuTLS pulled in GMP/nettle/hogweed and, being GnuTLS,
required `--enable-version3`; with the network stack gone those are gone
too, and the build is plain **LGPL-2.1-or-later**. Certificate trust now
means one thing — Apple's system trust store, evaluated once, in Swift —
instead of also auditing what a vendored GnuTLS does with it.

## How HTTP reaches the server now

The app's `FFmpegNetworkTransport` fetches and feeds media over
`URLSession`; libavformat itself never opens a socket.

## Rebuild and verify

Requires Xcode, Python 3.12+ and pkg-config. All compiler roles explicitly use
Apple Clang, including FFmpeg's host tools. No GCC installation is needed.

```sh
python3 scripts/build-ffmpeg-format.py --work /private/tmp/lagoon-libavformat-build
python3 scripts/build-ffmpeg-format.py --verify-only Artifacts/Libavformat.xcframework
```

The only thing the script downloads is FFmpeg's own checksum-pinned source
tarball; everything else it needs is in this repository. It retains upstream's
selected demuxers/muxers (including the `hls` demuxer — networking is compiled
out at the protocol layer, not the demuxer layer), builds only libavformat, and
packages iOS/tvOS arm64 devices, arm64/x86_64 simulators, and arm64/x86_64
macOS. Actual deployment targets are iOS/tvOS 26 and macOS 14. Static
framework metadata follows the repository's existing dav1d packaging
convention. `--groups` and `--output` allow temporary development builds;
commit all five platform groups.

`verify()` re-derives none of the above from trust — it checks the artifact's
file checksums; for every architecture, that no `_ff_http_protocol`,
`_ff_https_protocol`, `_ff_tls_protocol`, `_ff_tcp_protocol` or
`_ff_udp_protocol` symbol is defined and that no undefined symbol starts with
`_gnutls_`, `_nettle_`, `___gmpz_` or `___gmpn_`; and that each slice's
`config.h` reports `CONFIG_NETWORK 0`, `CONFIG_HLS_DEMUXER 1`, an
`FFMPEG_CONFIGURATION` string containing `--disable-network` and not
containing `--enable-version3`. `BUILD.json` records the source URL and
hash, `network: false`, `license`, the Xcode version, the full configure
flags per platform/architecture, and every artifact file's checksum. Absolute
toolchain paths are recorded for provenance; byte-identical output across
Xcode versions is not promised.

Source: https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.1.2

Source SHA-256: `9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7`.

FFmpeg's license notices accompany the artifact.

## The codec selection list

`scripts/ffmpeg-format-selections.txt` holds the 131 `--enable-muxer=` /
`--enable-demuxer=` / `--enable-encoder=` / `--enable-decoder=` flags, and the
four `--disable-*s` lines that scope them, which decide what this libavformat
supports. It is committed, not derived.

It came from MPVKit 1.0.0's own libavformat build — the source of the
`Libavcodec`, `Libavutil` and `Libswresample` pins — by parsing
`FFMPEG_CONFIGURATION` out of its `config.h`. Matching that set is what keeps
this build ABI-compatible with those three. The script used to download that
framework on every run purely to re-read the list, which meant the one script
able to rebuild libavformat without MPVKit could not itself run without it.
Capturing the list once removed that. The two `libdav1d`/`libuavs3d` decoder
flags in upstream's set are deliberately absent: dav1d is built here, and both
decoders are wired up through `Package.swift`.

The public headers the framework vends — `avformat.h`, `avio.h`,
`os_support.h`, `version.h`, `version_major.h` — are now copied out of the
extracted source tree rather than out of that download, so they cannot drift
from the code they describe. They were verified byte-identical to the headers
the previous artifact shipped, and the one patch this build applies touches
only `hls.c`. `config.h` and `config_components.h` continue to come from the
build itself.

To regenerate the list after an FFmpeg bump, build once and read it back out
of the artifact, which records every flag it was configured with. The exact
snippet is in the comment at the top of the file.

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
the app, alongside `FFmpegNetworkTransport`.
