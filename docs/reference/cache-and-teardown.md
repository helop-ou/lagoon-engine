# Playback cache and teardown

The byte cache in front of the demuxer, and how a player shuts down. The
contract is in the [engine guide](../engine.md).

The cache predates the URLSession transport. Where a read "falls back to the
native path", that path is now the same URLSession transport ([Network
transport](transport.md#network-transport)): a fallback changes the byte
source, never the security policy.

## The sparse range buffer

- Direct-play and direct-stream files read through one custom `AVIOContext`
  over a discardable sparse file under `Library/Caches/Lagoon/Playback`.
  Authenticated `Range` misses fill the file; repeated reads are local.
- If the server rejects or ignores byte ranges at open, the engine closes the
  partial context and reopens the original URL through the demuxer's own
  transport. A whole-body `200` is rejected before its body is delivered:
  treating it as a range would re-download an ever-growing prefix for every
  chunk.
- Transcoded HLS does not use the range buffer, because its manifests change
  while the server produces the rendition. An HLS resource cache exists only
  behind `-debug.experimentalPlaybackCache YES`: playlists untouched,
  immutable segments through bounded custom contexts. It is kept so the
  segment-boundary regression stays reproducible.

## Fill pacing

Proactive fill starts only once the initial cushion has reached the renderer,
and runs one 1 MiB chunk at a time. `PlaybackFillPolicy` (a pure, unit-tested
value type) decides what follows each chunk, from the cached media ahead of
the playhead and the throughput the chunk just measured:

- **Below `targetAheadSeconds`** (120 s of playback at the current rate), the
  next chunk follows after a yield of half the request's duration, so
  foreground reads keep a third of the link and a fast link never idles. This
  applies only when the chunk's media duration (its bytes over the title's
  average bitrate) exceeds the request plus the yield at the playback rate,
  with a 10% margin: in effect the link must carry about 1.65× the bitrate.
  Otherwise, or when cushion, bitrate or rate is unknown, it takes the gentle
  pace.
- **At or above the target**, the gentle pace: four times the measured request
  duration, capped at 8 s.
- The decision is per request with no history, so a seek, pause or rate change
  needs no reset. Do not gate on the cushion growing per chunk: a 1 MiB chunk
  holds 0.25 s of media only below about 33 Mbps, so every 4K title would
  stall at the gentle pace.
- Pacing measures the prefetch's own request, never the cache's aggregate,
  which foreground traffic also feeds.
- A 20 s cooldown follows buffering or a new stall. Pause allows full-speed
  fill; backgrounding cancels proactive work.
- The scheduler exists because Apple documents URLSession priority as a hint,
  not a bandwidth guarantee. Foreground misses stay high priority; proactive
  requests disallow constrained or expensive paths.

When playback catches up with a prefetch of the bytes it needs, the foreground
read promotes that request to foreground priority and waits up to two seconds
for it, rather than fetching the same range twice. Past that it fetches for
itself, so a seek never waits behind a stalled prefetch. `sharedFetchCount` and
`duplicateNetworkBytes` count both outcomes; the HUD's "Ahead" line and the
decode trace's `cacheMB`/`aheadMB`/`dupMB` show them. The host repository's
`scripts/fill-bench.sh` compares two builds' fill rates on one title.

## Size cap and the travelling window

The coordinator leaves 256 MiB of volume space free and gives the current
title half of the rest. A title smaller than that cap is buffered completely:
nothing is evicted, and fill wraps back to close early holes until the file is
contiguous.

A title **larger** than the cap is buffered through a window that travels with
the playhead. Filling to the cap and stopping is a cliff: past the filled edge
every 64 KiB read missed and fetched a 1 MiB request it could not store, which
is sixteen times the bandwidth and requests on the demux thread, and permanent
rebuffering about an hour into a large film.

- The window keeps `byteLimit / 8` (at most 256 MiB) behind the playhead for
  backward scrubbing and spends the rest ahead. When a request needs room, it
  frees the islands furthest from the playhead.
- The reserve is clamped to what exists behind the playhead, so near the start
  the window is `[0, cap]` and only slides once the playhead passes the
  reserve distance. Unclamped, a viewer a minute in buffered up to 256 MiB less
  than allowed.
- `preferredPrefetchOffset` follows every foreground read, so a backward seek
  re-centres the window on its next read. Anything evicted is simply
  refetched: the range set is the sole authority on what the file may be read
  for.
- Eviction reclaims real blocks with `F_PUNCHHOLE` over the block-aligned
  interior of a range, and the cap is checked against `st_blocks` as well as
  the range bookkeeping, or the file could grow past the free-space reserve.
  If the filesystem refuses to punch, the scope falls back to a fixed cap, and
  reads ask only for the bytes they were given, so the amplification never
  returns.
- The AVIO buffer is sized to the cache's request size, so one demux read is
  at most one network request even when nothing can be stored.
- `debug.playbackCacheCapMB` forces a small cap in DEBUG, so the window is
  visible within a minute.

Pausing freezes the window, not the fill. The demuxer parks on its
watermarks, so `preferredPrefetchOffset` stops moving, while the fill drops
its throttle because nothing competes for the link. The result is a
full-speed fill to the window's edge, then an idle 2 s poll. **Nothing is
evicted:** eviction runs only from a read that is short of capacity.

## Failures

- A failed cache read returns an I/O error, never EOF. EOF means a resource
  was read successfully to its end.
- URL loading retries transient failures. Range incompatibility does not
  retry, because the fallback open is faster and safer.
- A proactive fetch reports a `PlaybackPrefetchOutcome`. A `.failed` chunk
  (retries exhausted) backs off from 1 s, doubling to 30 s, and is retried, so
  fill resumes by itself once the link recovers. `.exhausted` on a windowed
  title means the read-ahead is full, and fill waits for the playhead to make
  room; on a title under the cap it means the file is complete.
- A sparse file is exposed as a local playback URL only after the whole
  server-declared byte range is validated and synchronized, so a hole can
  never pass for EOF.

## Progress reporting

- The legacy percentage reports only the contiguous prefix from byte zero,
  which drops to 0 on a windowed title once the head is evicted. The
  scrubber's islands stay accurate.
- File-byte fractions are not timeline fractions for variable-bitrate media.
  The engine pairs FFmpeg's video-packet byte positions with their timestamps
  as playback advances (a seek records an anchor before the first post-seek
  packet), and projects buffered ranges through the latest anchor. The active
  island stays joined to the playhead, and 0 and EOF stay exact.
- The HUD reports contiguous MiB of total MiB, percentage, hit rate, request
  count and latency. A `Playback Buffer Progress` signpost carries the same
  fraction and the stall count for Instruments.

## Scope ownership and teardown

**One active scope, at most one staged successor.** Dismissal, failure or
player replacement cancels requests and removes both. Episode advance removes
the old scope and promotes the staged one. Deletion waits for an in-flight
demux read on a utility queue, so the main actor never inherits file or
network teardown. Stale scope directories are discarded when a new
coordinator starts.

**Player exit is two-phase, and the first phase is synchronous.** Before the
host dismisses the player, the main actor cancels clocks, observer and
subtitle work, detaches system media state, marks the engine cancelled and
interrupts FFmpeg. Then:

- renderer stop, flush, queued sample release and renderer removal run on the
  pump queue;
- `FFmpegDemuxer.close()` releases the codec and decoder wrappers on the
  demux queue.

So dismissal never pays for hundreds of buffer releases or C decoder
destruction. The host's stopped-playback report is sent once, after the host
reads the final position, from a task holding copied values rather than the
engine. It never gates dismissal.

**A replacement player waits up to 15 s** for the outgoing engine's demux loop
and renderer set to retire. Renderer removal is asynchronous inside
AVFoundation and can take more than three seconds after high-resolution
playback. A timeout is recorded as `Playback Resource Retirement Timeout` and
aborts the replacement rather than overlap two pipelines on one display layer.

## Lifecycle checks

`Playback Lifecycle` signposts record live controllers, engines, demux loops,
renderer sets, unclean engine destructions and physical footprint at every
ownership change. A Debug-only accessibility probe exposes the same counters
to UI regressions. **The counters, not RAM, are the gate:** allocator caching
can keep footprint flat or high long after an engine has gone.

These run in a host's regression suite:

- `testPlaybackDismissSettingsReplayLifecycleAndStallBenchmark` (host script
  `scripts/playback-lifecycle-bench.sh`): play, dismiss, enter Settings,
  replay. Every cleanup point must reach 0/0/0/0, cleanup-to-cleanup footprint
  growth stay under 48 MB, replay startup growth under 96 MB, and at most one
  new stall while media time advances at least 10 s in a 15 s window. Three
  cycles by default (`LAGOON_LIFECYCLE_REPLAYS` overrides, capped at ten), so
  a small leak shows as a slope.
- `testControlledFrameLossPlaybackPerformance`: one item, three runs from the
  same position, each a 10 s warmup and a 60 s untouched media-time window.
  More than 1,000 frames, no corrupted frames, at most one stall, at most 1%
  loss, zero audio gaps, at most 0.5 percentage points run-to-run spread.

These allowances sit above simulator allocator noise and below one retained
decoded-video queue. Set Xcode performance baselines from hardware runs, and
never read a simulator's RAM figure as an Apple TV jetsam threshold. For a
live check, attach Instruments' Leaks or run `leaks` during the second window.

A simulator run is enough for an H.264 control. VC-1, HEVC, HDR and TrueHD
need a hardware bench against media that carries that codec:

```sh
LAGOON_LIFECYCLE_VC1_SERIES='<series name>' \
  scripts/playback-lifecycle-bench.sh 'platform=tvOS,id=<Apple-TV-UDID>'
```

The resolver picks an episode whose playback info actually declares VC-1, so
renamed files cannot quietly turn the bench into an H.264 test.
`testVC1DirectPlayMaintainsContinuousAudioAndVideo` uses the same discovery
and also requires Direct Play, the sparse buffer and local LPCM audio.

Stall recovery bounds are in [Queue and renderer
behavior](queues-and-renderers.md#stall-recovery).
