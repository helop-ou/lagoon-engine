# Playback cache and teardown

Playback engineering notes retained during the September 10, 2026
documentation cleanup. Start with the [engine
guide](../engine.md) and the [notes index](README.md).

## Playback cache and teardown

The cache predates the transport replacement described in [Network
transport](transport.md#network-transport). Where these notes say a read
falls back to libavformat's "native" HTTP path, that path is now the
URLSession transport too; what a fallback changes is the byte source, never
the security policy.

Release direct-play and direct-stream files use the sparse range buffer. One
custom `AVIOContext` lets libavformat read and seek through a discardable file
under `Library/Caches/Lagoon/Playback`; authenticated `Range` misses fill that
file and repeated reads are local. The engine tries this path first, but if
the server rejects or ignores byte ranges during open it closes the partial
context and immediately reopens the original URL through the demuxer's own
transport. A whole-body `200` is rejected before its body is delivered:
pretending it were a range would redownload and discard an ever-growing prefix
for every chunk.

Transcoded HLS does not use the range buffer at all. Its manifests are mutable
while the server produces the rendition, so a direct-file completion model does
not apply. The HLS resource-cache experiment survives only behind
`-debug.experimentalPlaybackCache YES`, leaving `.m3u8` playlists alone and
routing immutable segments through bounded custom contexts — enough to keep
the segment-boundary regression reproducible without shipping that ownership
to TestFlight.

The active direct file begins proactive fill only after the initial playback
cushion has reached the renderer, and fills cooperatively rather than in one
large background request: one 1 MiB chunk at a time, with `PlaybackFillPolicy`
(a pure, unit-tested value type) deciding what follows each chunk from the
cushion of cached media ahead of the playhead and the throughput the chunk
just measured. Below `targetAheadSeconds` (120 s of wall-clock playback at the
current rate), the next chunk follows after a yield of half the request's own
duration, uncapped so foreground reads keep a third of the link while a fast
link never idles, but only when the chunk's media duration (its bytes over the
title's average bitrate) exceeds the request plus that yield at the playback
rate with a 10 % margin: in effect the link must carry about 1.65 × the
title's bitrate. A link that can barely carry the title fails that test and
gets the gentle pace before any stall has to force it, so the scheduler is
self-limiting on tight links; an unknown cushion, bitrate or rate also keeps
the gentle pace. The decision is per request with no history, so a seek, pause
or rate change needs no reset. The first version of this guard required the
cushion to have grown by 0.25 s since the previous chunk; a 1 MiB chunk holds
0.25 s of media only below about 33 Mbps, so every 4K title fell back to the
gentle pace and the 1080p bench could not see it. At or above the target the
older pacing returns: four times the measured request duration, capped at 8 s.
Before this scheduler, the fill loop applied that pacing always, a fixed ~20%
duty cycle that capped read-ahead near 2 MiB/s however fast the link was.
Pacing measures the prefetch's own request, never the cache's aggregate that
foreground traffic also feeds. A 20-second cooldown follows buffering or a new
stall. Pause allows full-speed fill; backgrounding cancels proactive work. The
explicit scheduler exists because Apple documents URLSession priority as a
hint rather than a bandwidth guarantee. Foreground misses stay high priority,
and proactive requests disallow constrained or expensive paths.

When playback catches up with a prefetch of the very bytes it needs, the
foreground read promotes that in-flight request to foreground priority and
waits up to two seconds for it rather than starting a second request for the
same range, which used to move 2 MiB to store 1; past the bound it fetches for
itself, so a seek onto a stalled prefetch never waits behind it. The metrics
count both outcomes (`sharedFetchCount`, `duplicateNetworkBytes`) and the
HUD's "Ahead" line and the decode trace's `cacheMB`/`aheadMB`/`dupMB` fields
show them; `scripts/fill-bench.sh` compares two builds' fill rates on one
title.

The coordinator preserves 256 MiB of free volume space and permits one half of
the remainder for the current title. A declared resource smaller than that cap
buffers completely and keeps the whole-file scheduler: nothing is evicted, and
proactive fill wraps back to close early holes until the file is contiguous.

A title **larger** than the cap is buffered through a window that travels with
the playhead. Filling to the cap and stopping was a cliff, not a graceful
stop: once the playhead reached the filled edge every read missed, and because
a miss fetched a whole 1 MiB request while storing none of it, one 64 KiB AVIO
buffer cost a 1 MiB download and a round trip — sixteen times the bandwidth
and sixteen times the requests, serialized on the demux thread. The engine's
own cushion is only the sample queues (~4 s of compressed video), so that
state was permanent rebuffering roughly an hour into a large movie. The window
keeps `byteLimit / 8` (at most 256 MiB) behind the playhead for ordinary
backwards scrubbing and spends the rest ahead of it, freeing the islands
furthest from the playhead when a request needs room. The reserve is clamped
to what actually exists behind the playhead, so the window is a whole cap's
worth of file wherever it sits: near the start it stays `[0, cap]` and only
begins to slide once the playhead has passed the reserve distance. Without
that clamp its lower half hung off the front of the file and that capacity
went unspent — a viewer who paused a minute in buffered up to 256 MiB less
than the cache was allowed to hold. `preferredPrefetchOffset` follows every
foreground read, so a backwards seek re-centres the window on its next demux
read and the bytes now far *ahead* become the eviction candidates; anything
evicted is simply refetched, because the range set is the sole authority on
what the file may be read for.

Eviction reclaims real blocks with `F_PUNCHHOLE` over the block-aligned
interior of a range, and the cap is checked against `st_blocks` as well as the
range bookkeeping — logical eviction without physical reclaim would let the
file grow past the free-space reserve. If the filesystem refuses to punch, the
scope abandons the window and falls back to a fixed cap, but reads then ask
only for the bytes they were given, so the amplification never returns. For
the same reason the AVIO buffer is sized to the cache's request size: one
demux read is at most one network request even when nothing can be stored.
`debug.playbackCacheCapMB` forces a small cap in DEBUG so the window is
observable within a minute instead of after gigabytes.

A failed cache read returns an I/O error, never EOF: EOF is reserved for a
successfully read resource ending. URL loading retries transient failures;
deterministic range incompatibility does not retry, because the fallback open
is both faster and safer. A proactive fetch reports a
`PlaybackPrefetchOutcome` rather than a Boolean: a `.failed` chunk (the loader
exhausted its retries) backs off, doubling from 1 s to a 30 s cap, and is
retried, so fill resumes on its own once the link recovers, without a seek or
a new session; before this policy, a failure was indistinguishable from
completion and ended fill for the rest of the title, with the finished task
handle also blocking `resumeBufferFill`. Reaching the disk cap does not end
proactive fill for a windowed title — `.exhausted` there means the read-ahead
is full, so the controller waits for the playhead to make room rather than
giving up on the rest of the movie; for a title under the cap it means the
file is complete. A sparse file is exposed as a normal local playback URL only
after the complete server-declared byte range has been validated and
synchronized, so a hole can never masquerade as EOF.

Pausing freezes the window rather than the fill. The demuxer parks on its
queue watermarks, so `preferredPrefetchOffset` stops moving and low-priority
prefetch never advances it, while the fill loop drops its throttle entirely
because no foreground demux request is competing for the link. The result is a
full-speed fill up to the window's edge followed by an idle 2 s poll, and
**nothing is evicted**: eviction only runs from a read that is short of
capacity, so an idle cache never trims itself.

For the UI, the legacy percentage diagnostic reports only the contiguous
byte-zero prefix, which a windowed title drops to 0 as soon as the head is
evicted; the scrubber's islands stay accurate. Because file-byte fractions are
not timeline fractions for variable-bitrate media, it pairs FFmpeg's
video-packet byte positions with their media timestamps as playback advances
(a seek records an initial cursor anchor before the first post-seek packet
arrives) and projects buffered ranges piecewise through the latest anchor,
keeping the active island joined to the playhead while preserving 0 and EOF as
exact endpoints. The Playback HUD reports contiguous MiB/total MiB,
percentage, hit rate, request count and latency; a `Playback Buffer Progress`
signpost carries the same fraction and stall count for Instruments runs.

Cache ownership is part of the player lifecycle. There is one active scope
and at most one staged successor. Dismissal, failure, or player replacement
cancels requests and removes both; episode advance cancels/removes the old
scope and promotes the staged one. Deletion waits for an in-flight demux read
on a utility queue so the main actor does not inherit file/network teardown.
Stale scope directories are discarded when a new coordinator starts.

Player exit is deliberately two-phase, and its first phase is synchronous:
before the host dismisses the player the main actor cancels the clocks,
observer and subtitle work, detaches system media state, marks the engine
cancelled and interrupts FFmpeg. Renderer stop/flush, queued sample release
and renderer removal are then serialized on the existing pump queue, and the
FFmpeg codec/decoder wrappers are released by `FFmpegDemuxer.close()` on the
demux queue, so dismissal never pays for hundreds of queued media-buffer
releases or C decoder destruction. Only the host's stopped-playback report
stays asynchronous: it is sent exactly once, after the host reads the
engine's final position, from a task carrying copied values rather than
retaining the engine. That reporting never gates dismissal.

A replacement player waits up to 15 s for the exact outgoing engine's demux
loop and renderer set to retire. Renderer removal is asynchronous inside
AVFoundation and can exceed the old three-second allowance after
high-resolution playback. A timeout is recorded as `Playback Resource
Retirement Timeout` and aborts the replacement instead of silently overlapping
two media pipelines on one display-layer renderer.

`Playback Lifecycle` signposts record live controllers, engines, demux loops,
renderer sets, unclean engine destructions and physical footprint at every
ownership transition, and a Debug-only accessibility probe exposes the same
counters to the UI regressions. Those counters, not the RAM figure, are the
strong gate for AVFoundation objects: allocator caching can keep footprint
flat or elevated long after the owning engine has gone away.

`testPlaybackDismissSettingsReplayLifecycleAndStallBenchmark`, run by
`scripts/playback-lifecycle-bench.sh`, performs the hardware-shaped sequence —
play, dismiss, enter Settings, replay — and requires every cleanup point to
reach 0/0/0/0, cleanup-to-cleanup footprint growth under 48 MB, replay startup
growth under 96 MB, and at most one new stall while media time advances at
least 10 s in a 15 s CPU/memory/hitch window. It runs three replay/dismiss
cycles by default (a `LAGOON_LIFECYCLE_REPLAYS` test-environment value
overrides that, capped at ten) so a smaller per-cycle leak becomes a slope
instead of hiding beneath one allocator-noise allowance.
`testControlledFrameLossPlaybackPerformance` adds frame presentation to the
same gate: one item, three runs from the same position, each leaving the
simulator untouched for a 10-second warmup plus a 60-second media-time window,
requiring more than 1,000 frames, no corrupted frames, at most one stall, at
most 1% frame loss, zero enqueued audio gaps and no more than 0.5 percentage
points of run-to-run spread. Those allowances sit deliberately above simulator
allocator noise and below one retained decoded-video queue; set Xcode
performance baselines from repeated hardware runs, and never read one
simulator's absolute RAM number as an Apple TV jetsam threshold. For a live
secondary check, attach Instruments' Leaks or run `leaks` during the second
window.

A simulator run is sufficient for an H.264 control; VC-1, HEVC, HDR and
TrueHD need a hardware bench against media that actually carries that codec.
On a device with access to such a title, target it by name rather than
relying on the simulator fallback:

```sh
LAGOON_LIFECYCLE_VC1_SERIES='<series name>' \
  scripts/playback-lifecycle-bench.sh 'platform=tvOS,id=<Apple-TV-UDID>'
```

The resolver walks that series' episodes and picks one whose reported
playback info actually declares VC-1, so season or file naming changes
cannot quietly turn the benchmark into an H.264 test.
`testVC1DirectPlayMaintainsContinuousAudioAndVideo` uses the same discovery
for the dedicated legacy-codec gate, additionally requiring Direct Play, the
sparse direct-file buffer and local LPCM audio before applying the same
untouched 60-second presentation window and dismissal lifecycle assertions.

Stall recovery is bounded as well. An empty Lagoon queue must stay empty for
one second before the engine pauses Apple's shared clock; this prevents one
100 ms scheduling tick from turning a healthy renderer-owned sample into a
visible micro-stall. Normal refill resumes at the demuxer's 12-frame low-water
cushion; if it cannot rebuild that cushion within 5 s, the engine re-primes
audio, video, renderers and the clock at the current media position. The pure
`StallRecoveryPolicy` unit test makes an accidental return to an infinite
rate-zero polling loop a deterministic failure.
