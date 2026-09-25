# The engine

What the package guarantees, and the invariants a change must not break. The
mechanism and measurements behind each are in [`reference/`](reference/README.md).

## What this is

A sample-buffer playback engine for iOS and tvOS. FFmpeg demuxes;
VideoToolbox decodes, falling back to libavcodec. No `AVPlayer`, no
third-party Swift dependency.

It exists because `AVPlayer` will not play much of what people have: MKV,
Dolby Vision profile 7, interlaced H.264, VC-1, TrueHD, DTS. The engine reads
the container, decides per track whether the hardware takes the bitstream, and
feeds `AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer` under an
`AVSampleBufferRenderSynchronizer`.

## What it is not

It is handed a media source, track metadata, an optional credential and
configuration. Everything else is the host's: which server, which viewer,
which settings, whether diagnostics are collected, and what to do when
playback fails. When the engine needs something from the host's side it takes
an input or states a verdict. [Standards](standards.md#what-belongs-here-and-what-does-not)
has the rule.

## Pipeline

```text
PlayerEngine (protocol)
  └─ SampleBufferPlayerEngine
       ├─ FFmpegDemuxer → compressed packets
       ├─ VideoToolbox, or libavcodec + conversion → decoded frames
       └─ audio/video queues → AVSampleBuffer renderers and synchronizer
```

| Folder | Holds |
| --- | --- |
| `Sources/LagoonEngine/Engine/` | Demux, decode, render |
| `Transport/` | Byte sources, network transport, cache |
| `Subtitles/` | Parsing, decoding, cue lifetime |
| `Diagnostics/` | Traces, counters, benchmarks |

A host talks to `PlayerEngine`, never to `SampleBufferPlayerEngine` directly.
The protocol keeps FFmpeg's types out of a host's build and leaves room for a
second implementation.

## Network transport

- Every HTTP open, HLS playlists and segments included, goes through
  `FFmpegNetworkTransport` over URLSession. libavformat is built without its
  network stack. Do not restore FFmpeg's own HTTP or TLS as a cache fallback.
- System certificate trust, the host's credential, redirect rules,
  cancellation and `BoundedDownload`'s size caps (used for subtitles) apply to
  every streamed media path. The cap is a transport safeguard, not a download
  feature.
- Credentials travel in the authorization header, never in the URL.
- Cache incompatibility changes the byte source, never the security policy.
- Failures stay failures: only a successfully read resource ends in EOF.

Details: [transport](reference/transport.md) and the [FFmpeg build
record](../Artifacts/FFmpeg.README.md).

## Lifecycle

Each of these has regressed at least once.

- **Never revive a stopped engine, and never overlap two pipelines.** A
  replacement waits, with a bounded timeout, for the outgoing engine's demux
  loop and renderers to retire. A timeout is not permission to start anyway.
- **Stop is two-phase.** First, immediately: cancel clocks and work, and
  interrupt FFmpeg. Then renderer stop, flush and release run on the pump
  queue, and decoder destruction on the demux queue. Reporting never blocks
  dismissal.
- **A host holds the engine weakly from anything SwiftUI retains.** View
  builders and gesture closures must not capture an engine strongly: SwiftUI
  can keep old view values after a handoff, and a captured engine outlives its
  playback.
- **One active cache scope, at most one staged successor.** The cache is
  transient playback storage, not a library. One shared coordinator inside the
  package enforces this, not a per-engine property, because a successor is
  warmed while the outgoing engine plays and that engine shuts down before the
  next opens.
- **The engine decides whether to cache, and fills for itself.** A host passes
  an item ID and a `MediaDelivery` to `prepare` and reads `bufferState`. It
  does not build sessions or run the fill loop: everything the pacing reads
  (stall count, rate, duration, buffering) is engine state.

## Memory

- **A frame count alone is not a memory budget.** Decoded-frame byte budgets,
  reorder depth, queue watermarks and backpressure cover queued packets and
  decode work in flight. Forty-two frames is 250 MB at 1080p 10-bit and
  1.05 GB at 4K, in a process the system has killed at 2.1 GB. The arithmetic
  is in [the frame-loss notes](reference/frame-loss-bench.md).
- **Arm `requestMediaDataWhenReady` only while a queue has something to
  give.** A still-armed callback that returns empty-handed is a busy loop.
- **Compressed packets keep their FFmpeg backing buffer; decoded LPCM is
  copied into CoreMedia-owned storage at emit.** A zero-copy LPCM handoff
  leaked the entire decoded audio stream.
- Software 10-bit conversion uses the asynchronous Metal path. Making it
  synchronous loses its performance.

## Verdicts, not decisions

A failed playback produces a `PlaybackEngineFailure` whose `cause` is:

- `.undecodable`: the samples cannot be decoded here; only a re-encode changes
  that.
- `.delivery`: the container, the transport or an AVFoundation object failed;
  the same media may play if it arrives another way.

The verdict is all the engine offers. Whether another way exists, and whether
to try it, is the host's call; the ladder a host descends on `.delivery` is a
host concern.

The ladder descends only on a verdict about the samples. A lost VideoToolbox
session is rebuilt, not reported as undecodable, a damaged run of pictures in
a stream that decodes is dropped, and while video output is suspended a
decode failure is ignored. [Stream recovery](reference/stream-recovery.md)
has all three.

## Driving the clock from outside

For a host whose transport authority is elsewhere: a synchronised group, a
remote control surface, anything that decides when playback starts.

- `clockPosition` is the media clock as the synchronizer reports it, never the
  optimistic position a seek sets before anything is demuxed. While the clock
  is stopped for a load or seek, it returns the target position.
- `play(atHostTime:)` starts so the current position is presented at a named
  instant on `CMClockGetHostTimeClock()`, one every participant agreed on. A
  request that arrives while the engine is still buffering is passed to
  `beginPlayback` in place of its own near-future anchor.
- `setCorrectionRate(_:)` nudges a drifting member without touching `rate`,
  which is the viewer's choice. `PlaybackRatePolicy.effectiveRate` combines
  the two, and every media-time cushion, watermark and synchronizer rate is
  computed from it.
- `onSeekReady` fires from `beginPlayback` on every open and every seek,
  unlike the one-shot `onPlaybackStarted`.

## Diagnostics

The engine records events and reports incidents through
`EngineDiagnosticSink`. The default, `DiscardedDiagnostics`, discards
everything: a library that reported by default would report to its author
about someone else's users. A host that wants diagnostics installs a sink with
`EngineDiagnostics.use(_:)`.

String fields must pass a token rule (letters, digits, `.`, `_`, `-` and `,`).
A string that fails is dropped, not truncated, because a truncated URL is
still a URL.

## Where the detail lives

The [engineering notes index](reference/README.md) lists each note and what it
covers.
