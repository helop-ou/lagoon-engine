# Network transport

How media bytes reach libavformat. The contract is in the [engine
guide](../engine.md#network-transport); build provenance is in
[`FFmpeg.README.md`](../../Artifacts/FFmpeg.README.md).

## FFmpeg has no network stack

`scripts/build-ffmpeg.py` configures with `--disable-network
--disable-protocols --enable-protocol=file --enable-protocol=data`.
libavformat opens only local files and `data:` URIs, so nothing inside FFmpeg
makes a trust decision. Dropping the stack also dropped GnuTLS, GMP, nettle and
hogweed and the `--enable-version3` flag GnuTLS needed, so all four FFmpeg
libraries are LGPL-2.1-or-later, and libavformat shrank from 19 MB to 15 MB.

One patch remains: `Patches/0001-hls-scheme-without-network-protocols.patch`.
hls.c refuses a child URL whose scheme has no registered protocol, which
without a network stack is every http(s) URL. The patch classifies the scheme
from the URL text and hands the open to `io_open`. Without it, a transcode
fails with "Invalid data found when processing input" before the transport is
asked.

## The URLSession transport

`FFmpegNetworkTransport` installs on every `AVFormatContext` the demuxer opens
and owns `io_open`/`io_close2`. Every http/https open, the top-level URL and
every HLS child playlist, segment and key, becomes a `URLSessionByteSource`
behind the `FFmpegCachedIO` bridge.

- A ranged GET streamed with backpressure: suspended above 8 MiB buffered,
  resumed below 2 MiB.
- Accepted: a 206 at the requested offset, a 200 at offset 0, or a 200 with a
  bounded discard of up to 4 MiB. Any other status is an I/O error, never EOF.
- Transient errors retry from the current position up to 3 times, at
  0.25/0.5/1 s. A 4xx never retries.
- A 15 s idle timeout applies, and the demuxer's interrupt callback is polled
  every 100 ms.
- `crypto+https://…` is hls.c's scheme for AES-128 segments. It cannot sit on
  custom I/O, so `AES128CBCByteSource` fetches and decrypts those in Swift
  with CommonCrypto.
- `file:` and `data:` opens go straight to `avio_open2`; neither carries a
  network trust decision.

## Credentials

**The credential travels as a header, never in the URL.** CFNetwork writes a
failed task's full URL to the unified log, so a query token would leak on
every failed segment fetch.

- The host builds a `MediaRequestAuthorization` (for Jellyfin,
  `Authorization: MediaBrowser … Token="…"`) and passes it to `prepare`. The
  engine carries it unmodified to the transport and sets the header on every
  same-origin request.
- It strips `ApiKey`/`api_key` from a URL that already carries one, since a
  server-supplied `TranscodingUrl` can arrive with either spelling.
- Requests to any other origin are left as given, and the session delegate
  drops the header on a cross-origin redirect.
- The playback cache (`URLSessionPlaybackRangeLoader`/`PlaybackRangeRequest`
  in `Sources/LagoonEngine/Transport/PlaybackCache.swift`) applies the same
  authorization to every ranged request, including HLS child URLs the server
  generated.

## Trust and logging

- Certificate trust is ordinary URLSession system trust. It rejects
  self-signed, expired and wrong-host peers, and a private CA must be
  installed on the device, not trusted by the app.
- FFmpeg's raw stderr logging stays off, because its HLS errors print complete
  token-bearing URLs. The suppression lives in the transport.
- The demuxer (`FFmpegDemuxer.swift`) sets no `tls_verify`, `rw_timeout` or
  `reconnect*` options and never calls `avformat_network_init`; none of them
  mean anything without network protocols.
- **It does set `http_persistent` to 0.** hls.c's keepalive only reuses
  connections through FFmpeg's own HTTP protocol. Left on, it falls back to
  `io_open` per segment while keeping the previous context alive, leaking one
  `AVIOContext` per segment.

## Verification

Rebuild with `scripts/build-ffmpeg.py` and check with `--verify-only`: file
checksums, no http/https/tls/tcp/udp protocol symbols, no gnutls/nettle/gmp
references, `CONFIG_NETWORK 0` and `CONFIG_HLS_DEMUXER 1`. Read both flags
from `config.h` and `config_components.h`, since FFmpeg 8 split component
flags into a second header. Then run the host repository's simulator
certificate matrix, `scripts/test-ffmpeg-tls.py --all-unit-tests`, which
drives 32 cases through `FFmpegNetworkTransport`.

The transport suite runs against a scripted `URLProtocol` stub: streaming,
seek restart, non-ranged servers, retried and non-retried failures, dropped
connections, interrupts, AES-128 decryption, and close/closeAll. A companion
suite checks that network is compiled out of libavformat, that an interrupted
open returns `AVERROR_EXIT`, and that the certificate matrix runs through the
transport.

## Malformed discs

UDF mounting and Blu-ray/DVD title selection share a cancellable work budget:
64 KiB per metadata read, 32 MiB requested in total, 2,048 reads, 100,000
checked operations, and a 30-second deadline checked between reads and in
parser loops. Validation covers partition and image bounds, exact reads,
descriptor and playlist sections, continuation cycles and cumulative extent
arithmetic. Metadata reads bypass streaming read-ahead; playback still uses
it. An unsupported or malformed disc falls back to server delivery. The
demuxer owns its native context from allocation, so a setup failure releases
it even before `avformat_open_input` runs.
