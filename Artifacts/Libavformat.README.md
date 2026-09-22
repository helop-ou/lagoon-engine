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
python3 scripts/build-ffmpeg-format.py --verify-only Packages/LagoonFFmpeg/Artifacts/Libavformat.xcframework
```

The script downloads checksum-pinned sources, retains upstream's selected
demuxers/muxers (including the `hls` demuxer — networking is compiled out at
the protocol layer, not the demuxer layer), builds only libavformat, and
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
