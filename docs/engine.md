# The engine

What the package guarantees, and the invariants a change must not break. The
mechanism and the measurements behind each one are in
[`reference/`](reference/README.md).

## What this is

A sample-buffer playback engine for iOS and tvOS, built on FFmpeg for demuxing
and on VideoToolbox — falling back to libavcodec — for decoding. There is no
`AVPlayer` anywhere in it, and no third-party Swift dependency.

It exists because `AVPlayer` will not play a great deal of what people
actually have: MKV containers, Dolby Vision profile 7, interlaced H.264, VC-1,
TrueHD, DTS. The engine reads the container itself, decides per track whether
the hardware will take the bitstream, and feeds
`AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer` under an
`AVSampleBufferRenderSynchronizer`.

## What it is not

It is handed a media source, track metadata, an optional credential and
configuration. Everything else is the host's. The engine does not know what
server the media came from, who the viewer is, what a settings screen offers,
whether anyone is collecting diagnostics, or what should happen when playback
fails.

That boundary is the point of the package, and
[standards](standards.md#what-belongs-here-and-what-does-not) states it as a
rule with the reasoning. When the engine needs something from the host's side
of the line it takes an input or states a verdict.

## Pipeline

```text
PlayerEngine (protocol)
  └─ SampleBufferPlayerEngine
       ├─ FFmpegDemuxer → compressed packets
       ├─ VideoToolbox, or libavcodec + conversion → decoded frames
       └─ audio/video queues → AVSampleBuffer renderers and synchronizer
```

The demux/decode/render pipeline is in `Sources/LagoonEngine/Engine/`. Byte
sources, the network transport and the cache are in `Transport/`. Subtitle
parsing, decoding and cue lifetime are in `Subtitles/`. Traces, counters and
benchmarks are in `Diagnostics/`.

A host talks to `PlayerEngine`, never to `SampleBufferPlayerEngine` directly.
The protocol is the seam that makes a second implementation possible and keeps
FFmpeg's types out of a host's build.

## Network transport

Every HTTP open goes through `FFmpegNetworkTransport` over URLSession,
including HLS playlists and segments. The libavformat built by this repository
has its network stack compiled out. Do not restore native FFmpeg HTTP or TLS
as a cache fallback.

System certificate trust, the credential the host supplied, redirect rules,
cancellation, and the size-capped fetches `BoundedDownload` applies to
subtitles must apply to every streamed media path. That bound is a transport
safeguard, not a download feature.

Credentials travel in the authorization header rather than in token-bearing
URLs. Cache incompatibility changes the byte-source strategy, not the security
policy. Failures stay failures: only a successfully read resource's end is
EOF.

TLS validation is recorded in [transport
details](reference/transport.md), and the build itself in the [libavformat
build record](../Artifacts/Libavformat.README.md).

## Lifecycle

These have each regressed at least once.

- **Never revive a stopped engine, and never overlap two pipelines.**
  Replacement waits for the outgoing engine's demux loop and renderers to
  retire, with a bounded timeout. A timeout is not permission to start the
  successor anyway.
- **Stop is two-phase.** Cancel clocks and work, and interrupt FFmpeg,
  immediately. Then serialize renderer stop, flush and release on the pump
  queue, and decoder destruction on the demux queue. Reporting never blocks
  dismissal.
- **A host holds the engine weakly from anything SwiftUI retains.** View
  builders and gesture closures must not capture an engine strongly: SwiftUI
  can hold old view values after a handoff, and a captured engine outlives the
  playback it belonged to.
- **One active cache scope, at most one staged successor.** The cache is
  transient playback storage, not a library. The coordinator that enforces
  this is a single shared instance inside the package, not a per-engine
  property: a successor scope is warmed while the outgoing engine still
  plays, and an episode handoff shuts that engine down before the next one
  opens, so ownership has to outlive any one engine.
- **The engine decides whether to cache, and fills for itself.** A host
  passes an item ID and a `MediaDelivery` to `prepare` and reads
  `bufferState` back. It does not build sessions or run the fill loop:
  every input the pacing reads — stall count, rate, duration, whether the
  picture is buffering — is engine state, and a host running the loop can
  only get at it by reaching back across the boundary.

## Memory

- **A frame count alone is not a memory budget.** Decoded-frame byte budgets,
  reorder depth, queue watermarks and backpressure apply across queued packets
  and decode work in flight. Forty-two frames is 250 MB at 1080p 10-bit and
  1.05 GB at 4K, in a process the system has already killed once at 2.1 GB.
  The arithmetic is in [the frame-loss
  notes](reference/frame-loss-bench.md).
- **Arm `requestMediaDataWhenReady` only while a queue has something to
  give.** Returning empty-handed from a still-armed callback is a busy loop.
- **Compressed packets keep their FFmpeg backing buffer; decoded LPCM is
  copied into CoreMedia-owned storage at emit.** The zero-copy LPCM handoff
  that preceded this leaked an entire decoded audio stream.
- Software 10-bit conversion goes through the asynchronous Metal path. Making
  it synchronous changes its performance characteristics.

## Verdicts, not decisions

When playback fails the engine produces a `PlaybackEngineFailure` whose
`cause` is `.undecodable` — the samples cannot be decoded here, and only a
re-encode changes that — or `.delivery`, meaning the container, the transport
or an AVFoundation object failed and the same media may well play when it
arrives another way.

That verdict is the whole of what the engine offers. Whether there is another
way to ask for the media, and whether it is worth asking, is the host's, and
the engine deliberately cannot tell. The ladder a host descends on a
`.delivery` verdict is a host concern.

The ladder descends only on a verdict about the samples. A lost VideoToolbox
session is rebuilt rather than treated as undecodable, and while video output
is suspended a decode failure is ignored outright. [Stream
recovery](reference/stream-recovery.md) has both.

## Driving the clock from outside

Three hooks exist for a host whose transport authority is elsewhere — a
synchronised group, a remote control surface, anything that decides when
playback starts rather than asking for it now.

`clockPosition` is the media clock as the synchronizer reports it, never the
optimistic position a seek moves before anything is demuxed. While the clock
is stopped for a load or a seek it answers with the position being headed for.

`play(atHostTime:)` starts so that the current position is presented at one
named instant on `CMClockGetHostTimeClock()` — an instant every participant
agreed on, not "now, roughly". A request arriving while the engine is still
buffering is handed to `beginPlayback` in place of its own near-future anchor.

`setCorrectionRate(_:)` nudges a drifting member without touching `rate`,
which is the viewer's own choice. `PlaybackRatePolicy.effectiveRate` folds the
two together, and every media-time cushion, watermark and synchronizer rate is
computed from it.

`onSeekReady` fires from `beginPlayback` on every open and every seek, unlike
the one-shot `onPlaybackStarted`.

## Diagnostics

The engine records events and reports incidents in its own vocabulary through
`EngineDiagnosticSink`. The default sink, `DiscardedDiagnostics`, throws
everything away. A library that reported by default would be reporting to its
author about someone else's users, so a host that wants diagnostics installs a
sink with `EngineDiagnostics.use(_:)`.

String fields pass a token rule — letters, digits, `.`, `_`, `-` and `,` —
before they become fields, and a string that fails is dropped rather than
truncated, because a truncated URL is still a URL.

## Where the detail lives

| Note | Covers |
| --- | --- |
| [Decode](reference/decode.md) | Software decode, dav1d assembly, the Metal conversion stage, thread and frame-delay tuning, measurement method |
| [Queues and renderers](reference/queues-and-renderers.md) | Demux threading, seek and clock starts, HDR and Dolby Vision tagging, stall recovery, audio starvation |
| [Cache and teardown](reference/cache-and-teardown.md) | The sparse range buffer, fill policy, eviction, two-phase teardown |
| [Transport](reference/transport.md) | URLSession transport, the HLS scheme patch, TLS trust, disc images |
| [Codecs](reference/codecs.md) | Per-codec behaviour, passthrough audio, deinterlacing, subtitle rendering |
| [Stream recovery](reference/stream-recovery.md) | Missing bitstream descriptions, open-GOP seeks, reclaimed decode sessions, MPEG-TS |
| [System integration](reference/system-integration.md) | Audio session, spatialization, rate policy, suspension, display-match requests |
| [Frame-loss bench](reference/frame-loss-bench.md) | Decoded-frame memory ceilings and the arithmetic behind them |
