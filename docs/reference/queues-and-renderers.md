# Queue and renderer behavior

Demux threading, seeks, tagging, stalls and audio starvation. The contract is
in the [engine guide](../engine.md).

## Threading

- The demux loop runs on a serial queue and feeds two condition-protected
  sample-buffer queues. Renderer pumps drain them through
  `requestMediaDataWhenReady`. State and transport live on the main actor.
- Video and audio have independent high- and low-water marks. A full queue
  blocks the producer, and a consumer crossing its low mark wakes it: no
  polling, no sleeps.
- Every renderer data request is paired with `stopRequestingMediaData` before
  release.
- Teardown removes each renderer asynchronously at `.invalid` (Apple's
  immediate-removal sentinel) and waits for both completion callbacks before
  the next episode may attach a renderer set.

## Seeks and clock starts

- A seek stops the clock, serializes renderer flushes with enqueueing, resets
  the queues, seeks with `avformat_seek_file` on the selected video stream
  (`av_seek_frame` only as a demuxer compatibility fallback), then re-primes
  about 12 video buffers.
- Playback binds the first presentable media time to a near-future host time
  with `setRate(_:time:atHostTime:)`, so audio and video start on one
  deadline.
- A generation token stops an older priming callback from restarting playback
  after a newer seek.
- When AVFoundation sets `requiresFlushToResumeDecoding`, the engine runs the
  same seek-and-flush. Resume uses the same path.

## Audio tracks and delay

- Tracks are listed from the demuxer with per-type 1-based ordinals, the
  convention a server's `DefaultAudioStreamIndex` maps to. Switching
  re-demuxes from the current position with the new stream selected and the
  rest discarded inside libavformat.
- Audio delay follows mpv: positive delays audio. It re-stamps buffers at
  enqueue (`CMSampleBufferCreateCopyWithNewTiming`) and re-demuxes from the
  current position on change.

## HDR and Dolby Vision tagging

Without these tags the display renders BT.2020 PQ as washed-out SDR.

- The video format description carries colorimetry (primaries, transfer,
  matrix, range, chroma siting from codecpar) and HDR10 static metadata
  (mdcv/clli payloads rebuilt big-endian from FFmpeg side data).
- H.274 ambient viewing environment side data becomes Apple's 8-byte `amve`
  format-description extension and, after HEVC decode-ahead, a propagating
  sample attachment.
- Dolby Vision profile 5 becomes a `dvh1` sample entry with a `dvcC` atom
  (IPTPQc2 is unwatchable without the DoVi path). Profile 8 stays `hvc1` with a
  supplementary `dvvC`, so non-DoVi displays fall back to the base layer's
  HDR10/HLG tags. Profile 4 gets no atom and plays as HDR10 from the base
  layer.

## Profile 7 conversion

Profile 7 (`DOVIWithEL`/`DOVIWithELHDR10Plus`) is an HDR10 base layer with
type-63 enhancement-layer and type-62 RPU NAL units interleaved in one HEVC
track. `DolbyVisionProfileConverter` converts it to profile 8.1 in flight:

- Each type-62 RPU is rewritten with libdovi: `dovi_parse_unspec62_nalu` →
  `dovi_convert_rpu_with_mode(rpu, 2)` → `dovi_write_unspec62_nalu`, the same
  transform as `dovi_tool -m 2`. Type-63 units are dropped.
- The track is tagged `hvc1` with a supplementary profile 8.1 `dvvC`
  synthesized from the source record: profile 8, level and version copied,
  `rpu_present` 1, `el_present` 0, `bl_present` 1, BL signal compatibility id
  1.
- MEL sources keep their mapping curves and every trim. FEL sources lose the
  enhancement layer's residual (unusable on any Apple TV), and mode 2 also
  resets their luma and chroma curves to identity, because a FEL mapping needs
  that residual. Mode 4 is dovi_tool's mapping-preserving alternative. DM
  trims survive either way.
- A libdovi failure drops that packet's RPU and counts an error; it never
  stalls the stream. The HUD reports converted RPUs, dropped EL units, bytes,
  the EL type (FEL/MEL, also logged once per playback) and the error count.
- Only a single-track profile 7 with a DoVi configuration record in the
  container is converted, which means MKV remuxes. Disc images (MPEG-TS, no
  record) play as HDR10.
- libdovi is vendored, not built here, and its tvOS simulator slice is arm64
  only, so a host sets `EXCLUDED_ARCHS[sdk=appletvsimulator*] = x86_64`.
  Provenance and hashes: [`Libdovi.README.md`](../../Artifacts/Libdovi.README.md).

**Compatibility fallback.** The engine flag `debug.stripDoviEL` (default off)
drops both unit types and plays profile 7 as HDR10 from the base layer. A host
may expose it however it likes. `HEVCNALUnitRewriter` is the shared
length-prefixed NAL walker (keep, drop or replace) behind both paths.
Malformed payloads pass through untouched, and a rewritten packet loses
zero-copy. The EL and RPU units are 14.5% of an 86 Mbps bitstream, about four
units of parse-and-skip per frame for the hardware decoder, yet the one
hardware sample with stripping on measured worse (3.14% lost, 13 stalls, on a
degrading source). Neither default is settled on hardware.

## Stall recovery

- A stall is the clock reaching the last delivered video pts with a dry video
  queue before end of file. An empty queue must stay empty for one second
  before the engine pauses the shared clock, so one 100 ms scheduling tick
  cannot become a visible micro-stall.
- The engine holds the synchronizer (buffering) and resumes at the demuxer's
  12-frame low-water cushion. If that cushion is not rebuilt within 5 s, it
  re-primes audio, video, renderers and the clock at the current position.
  The `StallRecoveryPolicy` unit test fails if this ever becomes an unbounded
  rate-zero polling loop.
- `av_read_frame` separates `AVERROR_EOF` from read failures. Transient errors
  retry briefly; persistent ones surface as an error, never a fake end of file
  (which would move a host's resume point).
- At real EOF the audio decoder drains its coalescing tail.
- In an HLS master, the working set is restricted to the chosen video's
  program, so other variants never download segments or duplicate the track
  list.
- Completion is armed at the last observed audio or video sample end through
  the synchronizer's boundary observer. It waits for AVFoundation's internal
  queues, works when the container duration is unknown, and is never inferred
  from queue depth.

## Audio starvation

**Starvation is a question about both queues, but `audioQueue` depth does not
measure it.** `pumpAudio` drains the queue into `AVSampleBufferAudioRenderer`
for as long as the renderer is ready, so the buffered audio lives inside the
renderer and the engine's queue sits near zero on a healthy title. Buffered
seconds of that queue are the same mistake in different units. A version that
stopped the clock on an empty audio queue put every title into a
buffer/play/buffer loop.

The signal sits on the renderer side. The **delivery lead** is the
presentation end of the last audio sample enqueued into the renderer, minus
the synchronizer clock.

- It is nil until the first sample reaches the renderer, so startup and seeks
  cannot fake an event, and it resets on seek, flush and renderer replacement.
- Below 0.25 s times the playback rate, it records one `aDry` episode. By
  default it never stops the clock.
- `PlaybackStarvationPolicy` answers `.none`, `.video` or `.audio`. `.video`
  confirms and stops the clock. `.audio` is counted per episode: `aDry` in the
  HUD, `audioDry` in the bench. The bench's `audioStalls` is the audio-caused
  subset of confirmed stalls, not the dry count.
- `StallRecoveryPolicy` is video-only. Gating it on audio would hang every
  video stall until `reprimeAfter`, because the audio cushion it would wait
  for is not normally there. Tests pin both.
- The HUD shows `lead` beside Apple's
  `hasSufficientMediaDataForReliablePlaybackStart`, labelled `ready`. On the
  Apple TV `ready` reads 0 through an entire healthy direct play (lead 1.9–2.2
  s), so **nothing may gate on it alone.**

What the counter catches: a delivery dip shorter than the video cushion but
longer than what the audio renderer holds. The delivery-stall regression below
reaches a 0.15 s lead and one `aDry` with 45 video frames still queued, and the
HLS interleave produced the same shape until the intake fixed it.

**Simulate Audio Starvation** (Debug only) stops feeding the audio renderer
once per engine, five seconds in, for three seconds. Override both with
`-debug.starvationInjectionDelaySeconds` and
`-debug.starvationInjectionDurationSeconds`.
`testRendererSideAudioStarvationIsDetectedAndRecovers`, in a host's hardware
regression suite, proves the lead crosses the floor, `aDry` increments once,
the picture clock keeps running and the lead recovers. On release, the hold
discards audio that ended before the clock: a real recovery never sends the
renderer such samples, and they would use up the acceptance budget the resume
rule depends on. Nobody has checked by ear that sound returns in sync rather
than replaying the withheld seconds.

**Buffer on audio starvation** (`debug.bufferOnAudioStarvation`, off by
default). With it on:

- An audio episode takes the same one-second confirmation as video, stops the
  clock and counts as an audio stall (`stalls N (M audio)`).
- Recovery waits for the renderer to report sufficient data for a reliable
  start and be half a second clear of the floor, or to hold a full second of
  lead, as well as for its video frames. The renderer's flag decides because a
  renderer with the clock stopped takes about a second of audio and then stops
  asking; a fixed one-second threshold parked at 0.996 s.
- Audio in the engine's own queue does not count, for audio or video stalls:
  audio behind a renderer that is not taking it will not play, and counting it
  resumed into silence three times in four seconds.
- An `aDry` episode spans its own stall, or the dip right after resume counts
  twice.
- The default stays off. The Release `aDry` counter is the evidence that would
  justify turning it on.

Not solved: an audio-caused stall with the video backlog already at its
bounds cannot refill audio through the demuxer, because the backpressure wait
wakes only on a video dequeue, which a stopped clock never makes. The intake
below reads past the video limit for audio, so this now needs an interleave
skewed beyond the intake bounds. The five-second seek fallback repairs it.

## HLS packet order and the video intake

**An HLS fMP4 fragment is not interleaved.** Each fragment's `mdat` is one
video block followed by one audio block (72 HEVC samples, then 92–94 E-AC-3
samples). libavformat's HLS demuxer hands the inner MP4 demuxer a non-seekable
stream, so `av_read_frame` emits the whole video block before any of that
fragment's audio. Every direct-played MKV, by contrast, is finely interleaved.

Against a decoded video queue capped at 30 frames (1.25 s), priming used to
fill 30 frames, hit the hard limit and start the clock with no audio. The loop
then read one packet per video dequeue, so each fragment's audio arrived
roughly a fragment late. On the Apple TV (1080p HEVC, E-AC-3, video pinned at
`30/30/30`): the 3 s-fragment transcode rung swung the lead between +1 and
−1.2 s with 22 `aDry` in 70 s; the remux rung, one source GOP per fragment
(up to 10 s), reached −7 s with 13. The server was keeping up. The cache does
not change it: it changes delivery, not packet order.

**The fix: a compressed video intake in front of every decoder.**

- `VideoIntakeQueue` holds video read past the decoded-frame limit, still
  compressed: a `CMSampleBuffer` for VideoToolbox or the compressed renderer
  path, a `SoftwareVideoPacket` for the software stage. At 4K a decoded
  overshoot is unaffordable.
- `step()` hands video to `admitVideo`, which delivers straight through while
  the intake is empty and the decoded backlog is under its hard limit, and
  parks it otherwise. Decode order is always read order.
- When the stream has audio, `DemuxBackpressurePolicy.decision` keeps
  returning `.read` at the video hard limit until the app-side audio queue
  reaches its high water (180 packets cached, 360 uncached) or the intake
  reaches 600 access units or 128 MB. Both bounds hold a whole fragment,
  because the audio sits behind the video block.
- Priming does the same: at the decoded limit with audio short of its 1.25 s
  reserve, it parks video and reads on. The reserve is renderer-side delivery
  plus the app-side queue.
- End of file with video parked is pending; the loop drains the intake as the
  decoded queue makes room. Seek, flush and teardown empty the intake.
- The older `audioCanCoverDrain` gate reads app-side buffered seconds, which
  are near zero on any title with audio, so its batch-drain branch is
  effectively unreachable. The read-ahead rule is what keeps audio fed.

Learned on hardware:

- **A lead-triggered read-ahead is not enough.** Reading on only when the lead
  fell under a threshold still gave a 4K Dolby Vision remux seven dry episodes
  in 70 s: reading a 60 MB video block over the network outlasts any cushion
  the renderer holds. The read starts the moment the decoded queue is full,
  bounded by the audio high water. Direct play reaches audio within a few
  packets and is unaffected.
- **The intake drains from the consumer side.** The loop can sit in network
  reads for seconds, and when only it drained the intake the decoded queue ran
  dry behind a full one (`video=0/30/30 intake=151/151`). `pumpVideo` drains
  after every dequeue, under a feed lock shared with `admitVideo` so the two
  cannot interleave packets. The loop's backpressure waits are bounded at
  250 ms, because with the clock stopped nothing dequeues.
- **Audio from before the resume position must not count.** A fallback engine
  resumes partway into a fragment whose audio starts at the keyframe, and
  that stale audio filled the high water just when the renderer held least.
  `step()` drops audio ending at or before the last start position
  (`audioAdmissionFloorSeconds`, set by every prime), and priming measures its
  reserve as renderer-side delivery plus `bufferedDuration(after:)` the target.

Result on the Apple TV, 60 s bench windows: every rung `stalls 0 · audioDry 0`,
decoded queue `30/30/30`, lead 3.9–4.3 s, 0.21–0.69% dropped. Intake peaks: 216
on the 3 s transcode rung, 409 on the one-GOP remux, 277 on a 73 Mbps 4K DoVi
title (790–877 MB footprint), 102 on direct play (footprint unchanged at about
205 MB, lead up from 2 s to 4 s). A transcode that starves with intake, decoded
queue and audio all at zero is the server's encoder running below real time;
stall recovery is the answer to that.

Where it shows: `V cur/peak/hard +cur/peak` in the HUD, `intake=cur/peak` in
`DecodeTrace`, `videoIntake`/`videoIntakeMax` in the regression probe, beside
a `rung=` field the host names (a server's play-method vocabulary usually
reports remux and transcode the same). `DemuxReadAheadPolicyTests`,
`VideoIntakeQueueTests` and `SampleBufferQueueTests` pin the policy, the queue
and the post-target measure; `testForcedRemuxKeepsAudioFedWithinTheIntakeBound`
pins the bounds and `aDry` on a forced remux in the simulator.

**Simulate Delivery Stall** (Debug only, same timing overrides as Simulate
Audio Starvation). `testBoundedDeliveryOutageRecoversThroughStallWithoutReprime`
drives an eight-second demux outage into buffering and back out with the video
backlog inside the hard limit. It asserts no seek fallback only when the
confirmed stall was clearly shorter than the five-second rule, because the
compressed path coasts on up to 120 queued frames and a decoded path on 30. It
pins stall recovery, not the read-ahead. The Release HUD keeps
`V current/max/hard` and `reprime N`.

## Uncached streams get a bigger audio cushion

The sparse cache is on for direct play and direct stream, and off for an HLS
transcode, whose manifests change underneath it. Without a cache the demux
queues are the only buffer, so a segment hitch drains both and audio goes
silent at once. So the queues grow when there is no cache:

- **It keys on the cache, not the play method.** A transcode with
  `debug.experimentalPlaybackCache` on is cached; a direct play that fell back
  to the native transport is not.
- **Only audio grows.** Video holds decoded frames (24.9 MB each at 4K 10-bit,
  hence the hard limit of 30); audio holds compressed packets at about
  80 KB/s. Doubling the audio cushion costs about 1.5 MB, 26 MB in the worst
  case (8-channel float LPCM), against 746 MB already allowed for video.
- **The safety margin grows too**, from 1.25 s to 3 s. It is how much audio
  video must leave covered before parking on its own high water, and without a
  cache the drain it must survive is a network round trip.

The HUD shows the target depth (`A 200/360`). Turning the HLS cache on does
not fix the periodic HLS dropout: that is packet order, above.

## Accepted platform limits

TrueHD Atmos objects cannot be preserved on tvOS. An HLS transcode carries no
subtitles.
