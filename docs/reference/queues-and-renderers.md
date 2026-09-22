# Queue and renderer behavior

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [engine guide](../engine.md) and the
[notes index](README.md).

## Queue and renderer behavior

- **Threading**: the demux loop runs on a serial queue feeding two
  condition-protected sample-buffer queues; renderer pumps drain them via
  `requestMediaDataWhenReady`; state and transport live on the main actor.
  Independent video/audio high-water marks apply hysteretic backpressure and
  wake the producer when consumers cross their low-water marks, so a full
  queue blocks without polling or arbitrary sleeps. Every renderer data
  request is paired with `stopRequestingMediaData` before release. Teardown
  removes each renderer asynchronously at `.invalid` (Apple's
  immediate-removal sentinel) and waits for both completion callbacks before
  the next episode can attach a renderer set.
- **Seeks and clock starts** stop the clock, serialize renderer flushes with
  enqueueing, reset queues, use `avformat_seek_file` against the selected
  video stream (with `av_seek_frame` only as a demuxer compatibility
  fallback), then re-prime (~12 video buffers). Playback binds the first
  presentable media time to a near-future host-clock time with
  `setRate(_:time:atHostTime:)`, so audio and video start on one deadline. A
  generation token prevents an older priming callback from restarting after a
  newer seek. The engine observes `requiresFlushToResumeDecoding` and performs
  this same clean seek/flush recovery when AVFoundation requests it; resume
  uses the same path.
- **Audio tracks**: listed from the demuxer (per-type 1-based ordinals — the
  same convention the server's `DefaultAudioStreamIndex` maps to); switching
  re-demuxes from the current position with the new stream selected and the
  rest discarded inside libavformat.
- **HDR/DoVi tagging** (M3): the video format description carries colorimetry
  extensions (primaries/transfer/matrix/range/chroma siting from codecpar)
  plus HDR10 static metadata (mdcv/clli payloads rebuilt big-endian from
  FFmpeg side data). H.274 ambient viewing environment side data is serialized
  into Apple's 8-byte `amve` format-description extension and, after HEVC
  decode-ahead, a propagating sample attachment. Those tags make the display
  pipeline adapt HDR/EDR instead of rendering BT.2020+PQ as washed-out SDR.
  Dolby Vision: profile 5 becomes a `dvh1` sample entry with a `dvcC` atom
  (IPTPQc2 is unwatchable without the DoVi path), profile 8 stays `hvc1` plus
  supplementary `dvvC` (non-DoVi displays fall back to the base layer's
  HDR10/HLG tags), and profile 4 gets no atom and plays as HDR10 from the base
  layer.
- **Profile 7 conversion**: profile 7 (`DOVIWithEL`/`DOVIWithELHDR10Plus`)
  used to take that same no-atom path — RPU discarded along with the
  enhancement layer — so a profile 7 UHD Blu-ray remux (HDR10 base layer,
  type-63 enhancement-layer and type-62 RPU NAL units interleaved in one HEVC
  track) played as plain HDR10. `DolbyVisionProfileConverter`
  (`Sources/LagoonEngine/Engine/`) converts it live instead: every type-62
  RPU is rewritten to profile 8.1 with libdovi — `dovi_parse_unspec62_nalu` →
  `dovi_convert_rpu_with_mode(rpu, 2)` → `dovi_write_unspec62_nalu`, the same
  transform `dovi_tool -m 2` performs — the type-63 units are dropped, and the
  demuxer tags the track `hvc1` plus a supplementary profile 8.1 `dvvC`
  synthesized from the source record (profile 8, level and version copied,
  `rpu_present` 1, `el_present` 0, `bl_present` 1, BL signal compatibility id
  1). MEL sources keep their base-layer mapping curves and every trim. FEL
  sources lose the enhancement layer's residual — unusable on any Apple TV
  anyway — and libdovi's mode 2 resets their luma and chroma mapping curves to
  the identity polynomial too, since a FEL mapping needs that residual to
  apply; mode 4 is dovi_tool's old mapping-preserving behaviour. The DM trims
  survive. A libdovi failure on a packet drops that RPU and counts an error
  rather than stalling the stream; the HUD line reports converted RPUs,
  dropped EL units, bytes, the RPU header's EL type (FEL/MEL, also logged once
  per playback) and the error count. This applies only to a single-track
  profile 7 with a DoVi configuration record in the container — MKV remuxes;
  disc images (MPEG-TS, no such record) are untouched, as they were before
  this conversion existed. libdovi is vendored, not repo-built (no Rust
  toolchain here; a rebuild follows upstream's `build.sh`), and its tvOS
  simulator slice is arm64 only, so the project sets
  `EXCLUDED_ARCHS[sdk=appletvsimulator*] = x86_64`; provenance and per-slice
  hashes are in `Artifacts/Libdovi.README.md`.

  **Compatibility fallback**: an engine configuration flag (`debug.stripDoviEL`,
  default off) drops both unit types and plays profile 7 as HDR10 from the
  base layer — the behavior before profile 7 conversion existed. A host may
  expose this however it likes. The flag itself began as an experiment called
  "Strip DoVi Enhancement Layer", since retired.
  `HEVCNALUnitRewriter` is the shared length-prefixed NAL walker with
  keep/drop/replace behind both it and the converter (malformed payloads pass
  through untouched; a rewritten packet loses zero-copy). The fallback exists
  because P7's EL/RPU NALs are not free to carry even when unused — 14.5% of
  an 86 Mbps bitstream on Snowden, ~4 units per frame of parse-and-skip work
  for the hardware decoder — yet the one same-scene hardware sample with
  stripping enabled measured *worse* (3.14% lost, 13 stalls) on a run whose
  source throughput was degrading, so neither default is settled on hardware.
- **Stall recovery** (M6): when the clock catches up to the last delivered
  video pts with a dry queue and the file isn't over, the engine holds the
  synchronizer (buffering spinner) and auto-resumes once ~12 buffers rebuild.
  `av_read_frame` distinguishes `AVERROR_EOF` from read failures — transient
  errors retry briefly, persistent ones surface as the error overlay instead
  of fake-finishing the file (which would have moved the server resume point).
  At real EOF the audio decoder drains its coalescing tail. In HLS masters the
  working set is restricted to the chosen video's program, so other variants
  never download segments or duplicate the track list. Completion is armed at
  the last observed audio/video sample end through the render synchronizer's
  boundary observer, so it waits for AVFoundation's internal queues and also
  completes streams whose container duration is unknown; it is not inferred
  early from app queue depth.
- **Starvation is a question about both queues, not just video.** Stall
  detection originally tested `videoQueue` alone, so an audio queue at zero
  produced no stall and no buffering state: the film played on with the
  picture running and no sound while every indicator read healthy — `AudDrop`
  absent, `aGaps` 0, `stalls` 0. Nothing was being discarded; nothing was
  arriving.

  **The first attempt at this shipped in 0.1 (66) and was wrong.** It treated
  an empty audio queue as a stall and stopped the clock for it, which put
  every title with audio into a continuous buffer/play/buffer cycle. Reverted
  in 67. The reason:

  > **`audioQueue` depth is not a measure of audio starvation.**
  > `pumpAudio` drains it into `AVSampleBufferAudioRenderer` for as long as
  > the renderer reports `isReadyForMoreMediaData`, so the buffered seconds
  > live inside the renderer and Lagoon's queue sits near zero on a
  > perfectly healthy title.

  Reading buffered seconds instead of packet count does not rescue it — that
  is the trap: it looks like it should work, but the seconds are the same
  queue in different units, still the wrong side of the pump.

  The signal that ships sits on the renderer side of that boundary. Lagoon
  records the presentation end of the last audio sample actually enqueued into
  `AVSampleBufferAudioRenderer` and subtracts the synchronizer clock. That
  delivery lead is nil until the first sample reaches the renderer, so startup
  and seeks cannot manufacture an event, and it resets on seek, flush, and
  renderer replacement. Below 0.25 s times the current playback rate it
  records one `aDry` episode. It never stops the clock.
  `PlaybackStarvationPolicy` answers `.none`/`.video`/`.audio` from a
  snapshot; `.video` confirms and stops the clock exactly as it always did,
  while `.audio` is counted per episode in the HUD (`aDry`) and the bench
  (`audioDry`) — the bench's `audioStalls` is the audio-caused subset of
  confirmed stalls, not the dry-episode count. `StallRecoveryPolicy` is
  video-only, and gating it on audio as well was the second half of the same
  mistake: it would have hung every video stall until `reprimeAfter`, since
  the cushion it waited for is not normally there. Both are pinned by tests.
  The HUD shows `lead` alongside Apple's
  `hasSufficientMediaDataForReliablePlaybackStart`, labeled `ready` — which on
  the paired Apple TV reads 0 for the whole of a healthy direct play,
  including inside a stall, so **nothing may gate on it alone** (the lead on
  that run sits at 1.9–2.2 s).

  The original reproduction no longer reproduces: the 64.5 Mbps source "the
  server was transcoding" was the server rebuilding a 64.8 GB Blu-ray image in
  real time because Lagoon could not open the image itself. Reading the disc
  directly removed the transcode and the cutouts with it. The shape the
  counter catches is a delivery dip shorter than the cushion that keeps video
  from stalling but longer than what the audio renderer holds — the
  delivery-stall regression below reaches a 0.15 s lead and one `aDry` with 45
  video frames still queued, and the HLS interleave produces the same shape
  unaided (the fix is below).

  **Simulate Audio Starvation** injects that shape deterministically. It is
  Debug-only, absent from Release; it stops feeding the audio renderer once
  per playback engine, five seconds in for three seconds, both delays
  overridable with
  `-debug.starvationInjectionDelaySeconds` and
  `-debug.starvationInjectionDurationSeconds`. The regression
  `testRendererSideAudioStarvationIsDetectedAndRecovers`, which runs in a
  host's own hardware regression suite because it needs an application to
  drive, proves the lead crosses the floor, `aDry` increments once, the
  picture clock keeps running, and the lead recovers after release. On release
  the hold discards audio that ended before the clock, because a real recovery
  never hands the renderer such samples and they would use up the acceptance
  budget the resume rule depends on. What the counters cannot say is what the
  hold sounds like: silence through it, picture moving across it, sound
  returning in sync rather than replaying withheld seconds late. That is what
  the code is written to do — an earlier version of this passage claimed it as
  verified when nobody had actually checked by ear.

  The buffering response exists behind `debug.bufferOnAudioStarvation`
  ("Buffer on Audio Starvation", off by default). With it on, an audio episode
  takes the same one-second confirmation as video, stops the clock and counts
  as an audio stall (`stalls N (M audio)`); recovery resumes once the renderer
  reports sufficient data for a reliable start and is half a second clear of
  the floor, or has a full second of lead, as well as its video frames. The
  renderer's own flag decides because a renderer with the clock stopped
  accepts about a second of audio and then stops asking: in the simulator a
  fixed one-second lead threshold parked at 0.996 s and fell to the seek
  fallback every time. Audio waiting in Lagoon's queue is deliberately not
  counted — audio behind a renderer that is not taking it is not audio that
  will play, and counting it resumed a held renderer into silence three times
  in four seconds; the same condition applies to video-caused stalls so a
  resume with a dry renderer cannot stutter back into silence. An `aDry`
  episode spans its own stall, because buffering answers no starvation and
  ending the episode there counted the dip right after resume as a second one.
  **The default stays off**: it originally waited on the read-ahead fix below,
  without which the mode would have stopped the clock a dozen times a minute
  on every transcode and remux; with that fixed, the `aDry` counter in Release
  is the evidence that would justify flipping it.

  One caveat is deliberately not solved: an audio-caused stall reached with
  the video backlog already at its bounds cannot refill audio through the
  demuxer, because the backpressure wait wakes only on a video dequeue that a
  stopped clock never makes. Before the read-ahead fix below, that bound was
  the video hard limit; the intake now reads on for audio past it, so the
  shape needs an interleave skewed by more than the intake bounds, and the
  five-second seek fallback with its bounded reprime is the repair it gets.

- **`A 0` is not a demux refill failure.** The report was first dismissed as
  invalid, then reopened once a real mechanism turned up underneath it. It
  read the same app-side queue as the starvation bug above — video at its
  hard limit, audio apparently stuck at zero — and assumed the demux loop
  could not refill a starved audio queue. That premise did not hold, for the
  reason above. The mechanism underneath it did: one-slot pacing at the video
  hard limit is harmless while audio is interleaved finely with video, which
  every direct-played MKV is. An HLS fMP4 segment is not: each
  fragment's `mdat` is one contiguous video block followed by one contiguous
  audio block (72 HEVC samples, then 92–94 E-AC-3 samples, per `moof`, checked
  with a box parser on three segments), and libavformat's HLS demuxer hands
  the inner MP4 demuxer a non-seekable stream, so `av_read_frame` emits the
  whole video block before any of that fragment's audio (`ffprobe` on the live
  playlist: V×72, A×93, V×72, A×94, …; the same bytes concatenated into a
  seekable file come out interleaved by DTS). Against a decoded video queue
  capped at 30 frames (1.25 s) that means `primeAndStart` fills 30 frames,
  hits the hard limit, and starts the clock with no audio delivered at all;
  the loop then reads one packet per video dequeue, so a fragment's audio
  arrives roughly fragment length minus the cushion late. Measured with the
  renderer-side lead on the paired Apple TV, 1080p HEVC with E-AC-3, video
  pinned at `30/30/30` and never stalling: the transcode rung (3 s fragments)
  sawtooths the lead between about +1 s and −1.2 s with 22 `aDry` episodes in
  70 s; the remux rung, whose fragments are one source GOP (keyframes up to 10
  s apart here), reaches −7 s with 13 — the same symptom as the starvation bug
  above, with the server demonstrably keeping up, matching the debunked
  reproduction's finding that the cutouts track the HLS path rather than
  server speed. `debug.experimentalPlaybackCache` does not change it (same
  sawtooth, −7.2 s), as expected: the cache changes delivery, not the order
  the HLS demuxer emits packets in.

  **The fix: a compressed video intake in front of every decoder.**
  `VideoIntakeQueue` holds video the demux loop has read past the
  decoded-frame limit, still compressed: a `CMSampleBuffer` for VideoToolbox
  or the compressed renderer path, a `SoftwareVideoPacket` for the software
  stage. Compressed is the point — at 4K the decoded overshoot is not
  affordable. `step()` hands video to `admitVideo`, which delivers straight to
  the next stage while the intake is empty and the decoded backlog is under
  its hard limit, and parks it otherwise, so decode order is the read order
  regardless of which path a packet took. `DemuxBackpressurePolicy.decision`
  no longer waits one slot at a time at the video hard limit when the stream
  has audio: it returns `.read` until the app-side audio queue reaches its
  high water (180 packets cached, 360 uncached) or the intake reaches its own
  bounds, 600 access units or 128 MB, both chosen to hold a whole fragment
  because the audio block is behind the video block and the read-ahead only
  helps if it reaches it. Priming reads the same way: at the decoded limit
  with audio still short of its 1.25 s reserve it parks video and reads on,
  measuring the reserve as renderer-side delivery plus the app-side queue,
  since the pump may already have handed the renderer part of it. End of file
  with video still parked is a pending state; the loop drains the intake as
  the decoded queue makes room and finishes then. Seek, flush, and teardown
  empty the intake. The older `audioCanCoverDrain` gate in the same policy
  reads app-side buffered seconds, which are structurally near zero on any
  title with audio, so the batch-drain branch it guards is effectively
  unreachable there; the read-ahead rule is what keeps audio fed.

  Three things about the shape were learned on hardware, not designed:

  - **A lead-triggered read-ahead is not enough.** The first version read on
    only when the renderer-side lead fell under a threshold (1.0 s, then 1.5
    s). On a 1080p transcode it worked, pinning the lead at the threshold; on
    a 4K Dolby Vision remux it still counted seven dry episodes in 70 s,
    because reading a 60 MB video block over the network takes longer than any
    cushion the renderer holds. The read has to start the moment the decoded
    queue is full, and the audio high water is what bounds it. Direct play is
    unaffected: a finely interleaved stream reaches audio within a few packets
    and the loop waits at the audio high water.
  - **The intake must drain from the consumer side.** With the loop reading
    ahead it sits in network reads for seconds at a time, and when only the
    loop drained the intake the decoded queue ran dry behind a full one
    (`video=0/30/30 intake=151/151`, frames dropping by the dozen).
    `pumpVideo` now drains after every dequeue, under a feed lock shared with
    `admitVideo` so the two feeders cannot interleave packets. The loop's own
    backpressure waits are bounded at 250 ms for the same reason in reverse:
    with the clock stopped nothing dequeues, and the loop has to re-evaluate
    the policy on its own.
  - **Audio from before the resume position counts against the read-ahead.**
    The first clean remux run produced one `aDry` episode in the first second
    after every rung switch: the fallback engine resumes a few seconds into a
    fragment whose audio block starts at the keyframe, so priming read that
    fragment's audio from its start, and the part before the resume position
    sat in the app-side queue counting toward the audio high water — pausing
    the read-ahead exactly when the renderer held least. `step()` now drops
    audio that ends at or before the position playback last started from
    (`audioAdmissionFloorSeconds`, set by every prime), and priming measures
    its reserve as renderer-side delivery plus `bufferedDuration(after:)` the
    target.

  Measured on the paired Apple TV, 60 s bench windows, no fault injected:
  every rung reported `stalls 0 · audioDry 0` with the decoded queue at
  `30/30/30`, the lead settled at 3.9–4.3 s and 0.21–0.69 % of frames dropped.
  Intake peaks stayed well inside the 600 bound — 216 on the 3 s transcode
  rung, 409 on the one-GOP remux, 277 on a 73 Mbps 4K DoVi title (790–877 MB
  footprint), 102 on direct play (footprint unchanged at ~205 MB), which
  settles at about 95 parked frames because the sparse cache only serves a
  window ahead of the playhead and whose lead doubled from 2 s to 4 s now that
  the app-side audio queue holds what the renderer will not take yet. One
  transcode run starved after 40 s with intake, decoded queue and audio all at
  zero: the server's HEVC re-encode running below real time. The read-ahead
  brings the client closer to the encoder's edge, so it reaches that wall
  sooner than the old pacing did, but that is upstream starvation and stall
  recovery is the right answer to it.

  The intake reads as `V cur/peak/hard +cur/peak` in the HUD,
  `intake=cur/peak` in `DecodeTrace` and `videoIntake`/`videoIntakeMax` in the
  regression probe, beside a `rung=` field the host names, because a
  server's own play-method vocabulary usually reports a remux and a full
  transcode identically. `DemuxReadAheadPolicyTests`, `VideoIntakeQueueTests` and
  `SampleBufferQueueTests` pin the policy, the queue and the post-target
  measure; `testForcedRemuxKeepsAudioFedWithinTheIntakeBound` pins the bounds
  and `aDry` on a forced remux in the simulator.

  **Simulate Delivery Stall** is a Debug-only fault of the same kind, using
  the same timing overrides as Simulate Audio Starvation. Its
  regression, `testBoundedDeliveryOutageRecoversThroughStallWithoutReprime`,
  drives an eight-second demux outage into buffering and back out with the
  video backlog inside the hard limit. It asserts the seek fallback absent
  only when the confirmed stall was clearly shorter than the five-second rule,
  because the compressed path coasts on up to 120 queued frames while a
  decoded path holds 30, and no single hold fits both. It pins the existing M6
  stall recovery path; it is not evidence about the read-ahead problem above.
  The Release HUD keeps `V current/max/hard` and `reprime N` regardless.
- **A stream with no cache gets a bigger demux cushion.** The sparse AVIO
  cache is on for direct play and direct stream and off for a transcode,
  because an HLS transcode has mutable manifests and a byte-range
  cache over a playlist that changes underneath it is not shippable. But "no
  byte-range cache" had become "no buffering of any kind" — no sparse cache,
  no proactive range fill, no playhead prefetch — leaving the demux queues as
  the only thing between the network and the renderers, so a hitch in segment
  delivery stalls the read directly, both queues drain, and audio goes silent
  at once. The queues are therefore a bigger cushion when there is no cache,
  and three things about that are deliberate:

  - **It keys on the cache, not the play method**, so the two compose: a
    transcode with `debug.experimentalPlaybackCache` on is not uncached, and a
    direct play that fell back to the native transport is.
  - **Only audio grows.** Video's queue holds decoded frames — 24.9 MB each at
    4K 10-bit, which is why its hard limit is 30 — while audio holds
    compressed packets at roughly 80 KB a second. Doubling the audio cushion
    costs about 1.5 MB against a video queue already permitted 746 MB; the
    worst case, a locally decoded 8-channel track held as float LPCM, is about
    26 MB. Audio is also the half with no cushion of its own, which is why a
    starved transcode reaches the viewer as silence over a moving picture
    rather than as a freeze.
  - **The safety margin grows too** (1.25 s to 3 s). That is the margin video
    must leave audio covered for before it may park on its own high water, and
    without a cache the drain it has to survive is a network round trip rather
    than a cache read. It is the half that keeps the loop reading for audio
    instead of parking on video.

  The HUD shows the depth being aimed for (`A 200/360`), so which profile is
  in force is visible rather than inferred from a missing line. Whether the
  HLS cache scope is sound enough to enable outside DEBUG is a separate,
  independent question — a cushion helps a stream that has no cache, and
  turning the cache on is what would stop it being one — and it is not the
  answer to silence either way: the cache does not stop the periodic dropout
  on the HLS rungs, because that is the packet-order problem above, not a
  delivery problem.
- **Audio delay** (M6): mpv convention, positive delays audio; applied by
  re-stamping buffers at enqueue (`CMSampleBufferCreateCopyWithNewTiming`) and
  re-demuxing from the current position on change.
- **All engine milestones (M1–M6) were verified end-to-end on hardware, closed
  out 2026-08-17.** Accepted platform limits: TrueHD Atmos objects are
  unpreservable on tvOS, and an HLS transcode carries no subtitles.
