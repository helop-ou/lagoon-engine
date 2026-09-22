# Network transport

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [engine guide](../engine.md) and the
[notes index](README.md).

## Network transport

libavformat's own network stack is gone. The owned build
(`scripts/build-ffmpeg.py`) passes `--disable-network
--disable-protocols --enable-protocol=file --enable-protocol=data`. The
library used to speak HTTP, HTTPS and TLS itself; now it opens only local
files and `data:` URIs. Nothing is left inside FFmpeg for a certificate to
fool.

That also dropped the GnuTLS, GMP, nettle and hogweed static libraries,
along with the `--enable-version3` flag GnuTLS's license required.
libavformat's build is now plain LGPL-2.1-or-later, and the xcframework
shrank from 19 MB to 15 MB. libavcodec, libavutil and libswresample are
built by the same configure, so the same holds for all four.

One patch remains: `Patches/0001-hls-scheme-without-network-protocols.patch`.
hls.c refuses any child URL whose scheme has no registered protocol, and
without a network stack that is every http(s) URL. The patch lets hls.c
classify the scheme from the URL text instead and hand the open to
`io_open`. Without the patch, a transcode fails to open with "Invalid data
found when processing input" before the transport is ever asked.

`FFmpegNetworkTransport` installs on every `AVFormatContext` the demuxer
opens and owns `io_open`/`io_close2`. Every http/https open the demuxer
makes becomes a `URLSessionByteSource` behind the existing `FFmpegCachedIO`
bridge. That covers the top-level URL and every HLS child playlist, segment
and key. It is a ranged GET streamed with backpressure: suspended above
8 MiB buffered, resumed below 2 MiB. A 206 at the requested offset or a 200
at offset 0 is accepted, and so is a 200 with a bounded discard up to
4 MiB. Any other status is an I/O error and is never reported as EOF.
Transient errors retry from the current position up to 3 times, at
0.25/0.5/1 s; a 4xx never retries. A 15 s idle timeout applies, and the
demuxer's interrupt callback is polled every 100 ms.

`crypto+https://…` is hls.c's own scheme for AES-128 segments. It can't
sit on custom I/O, so those opens don't go through FFmpeg's crypto protocol
at all: `AES128CBCByteSource` fetches and decrypts them in Swift with
CommonCrypto instead. `file:` and `data:` opens still go straight to
`avio_open2`, because neither carries a network trust decision.

The credential travels as a header, never in the URL. CFNetwork writes a
failed task's full URL into the unified log, so a query token would have
leaked into diagnostics on every failed segment fetch. A header never does.

`MediaRequestAuthorization` sets the `Authorization: MediaBrowser …
Token="…"` header on every same-origin request instead. The host builds it
and hands it in with the media request; the engine carries it through
`prepare` and the demuxer to the transport unmodified. It also strips
`ApiKey`/`api_key` from a URL that already carries one before issuing the
request. A server-supplied `TranscodingUrl` can still arrive with either
spelling. Requests to any other origin are left exactly as given, and the
session delegate drops the header on a cross-origin redirect.

The playback cache (`URLSessionPlaybackRangeLoader`/`PlaybackRangeRequest`
in `Sources/LagoonEngine/Transport/PlaybackCache.swift`) applies the same
authorization to every ranged request it makes, including HLS child
playlists and segments whose server-generated URLs may still carry a
credential in the query string. No first-party media request built by the
engine carries the token in its URL any more.

Certificate trust is now whatever URLSession enforces: ordinary system
trust evaluation. It rejects self-signed, expired and wrong-host peers,
and it requires a private CA to be installed on the device rather than
trusted by the app. The experimental HLS cache still leases immutable
segments when enabled, on the same transport. FFmpeg's raw stderr logging
is still disabled, because its HLS errors print complete token-bearing
URLs. That suppression now lives in the transport, alongside Lagoon's
error-code and playback diagnostics.

The demuxer (`FFmpegDemuxer.swift`) no longer sets `tls_verify`,
`rw_timeout` or any `reconnect*` option, and it no longer calls
`avformat_network_init`. None of that means anything to a build with no
network protocols. It does still set `http_persistent` to 0. hls.c's
keepalive reuses a segment's connection only through FFmpeg's own HTTP
protocol; left on, it falls back to `io_open` for every segment while
keeping the previous context alive, leaking one `AVIOContext` per segment.
With it off, each segment closes through `io_close2` as it finishes.

Rebuild with `scripts/build-ffmpeg.py` and verify with
`--verify-only`. That checks checksums, confirms the http/https/tls/tcp/udp
protocol symbols are absent, confirms there are no gnutls/nettle/gmp
references, and confirms `CONFIG_NETWORK 0` and `CONFIG_HLS_DEMUXER 1`.
Read both flags from `config.h` and `config_components.h`, since FFmpeg 8
split component flags into a second header. Then run the controlled
simulator certificate matrix with `scripts/test-ffmpeg-tls.py
--all-unit-tests`, which drives its 32 cases through
`FFmpegNetworkTransport` instead of libavformat's own TLS.

The transport suite covers it against a scripted `URLProtocol` stub: streaming, seek restart,
non-ranged servers, retried and non-retried failures, dropped connections,
interrupts, AES-128 decryption, and close/closeAll.
A companion suite checks that network is compiled out of libavformat, that an interrupted open returns
`AVERROR_EXIT`, and that the same certificate matrix runs through the
transport.

Build provenance, exact behavior and prerequisites are documented in
[`FFmpeg.README.md`](../../Artifacts/FFmpeg.README.md).

## Malformed discs

UDF mounting and Blu-ray/DVD title selection share a cancellable work
budget: 64 KiB per metadata read, 32 MiB requested in total, 2,048 reads,
100,000 checked operations, and a 30-second deadline checked between
synchronous reads and in parser loops. Validation covers partition and
image bounds, exact reads, descriptor and playlist sections, continuation
cycles, and cumulative extent arithmetic. Metadata cache reads bypass
streaming read-ahead; ordinary playback still uses it. Unsupported or
malformed discs fall back to the existing server-delivery path. The
demuxer owns its native context from allocation, so setup failures release
it even before `avformat_open_input` runs.
