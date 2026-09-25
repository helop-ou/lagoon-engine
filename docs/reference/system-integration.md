# System integration

The system behaviour `AVPlayer` would otherwise supply, done without a second
player. The contract is in the [engine guide](../engine.md).

## System media integration

### Audio session

`PlaybackAudioSession` activates `.playback` / `.moviePlayback`, enables
multichannel content, uses `.longFormVideo` on iOS, and deactivates with
`notifyOthersOnDeactivation` when playback ends.

- Interruption callbacks are idempotent: they resume only if the item was
  playing and the system sets `shouldResume`.
- Route changes pause when a personal output (wired, Bluetooth, AirPlay)
  disappears, but not on tvOS HDMI mode changes.
- A media-services reset re-establishes the category and the active session.

### Audio spatialization

One factory, `SampleBufferPlayerEngine.makeAudioRenderer`, builds every audio
renderer, so a replacement after a failure or reset sounds the same. It sets
spatialization to `monoStereoAndMultichannel`, matching `AVPlayerItem`'s
video default; `AVSampleBufferAudioRenderer` defaults to `multichannel` alone,
which plays stereo soundtracks flat on AirPods. The property only grants
permission: the viewer's Spatial Audio setting still decides, and it does
nothing over HDMI. A test pins both defaults, so an SDK that closes the gap
fails it and the override can go.

### Playback speed

`PlaybackRatePolicy`:

- A fixed envelope from 0.5× to 2×, with six `supported` stops (0.5, 0.75, 1,
  1.25, 1.5, 2) for a stepped control.
- `clamped(_:)` holds any input inside the envelope.
- `stepped(from:by:)` moves to the next stop and clamps at both ends rather
  than wrapping. It starts from the nearest stop, because a system
  integration such as Remote Command Center can set a rate like 1.1.
- `effectiveRate(userRate:correction:)` folds in a drift-correction
  multiplier, so everything downstream scales by one number.
- `title(_:)` formats a rate with no trailing zeros and a multiplication sign;
  `identifier(_:)` gives a stable identifier for accessibility and UI tests.

Pause, seek, buffering, renderer recovery, delivery fallback and handoff to a
successor engine all keep the rate. Every audio renderer uses the time-domain
pitch algorithm, including after a media-services reset, so rate never changes
pitch. Stall recovery, the delivered-PTS margin, priming and demux watermarks
scale their media-time cushions by rate; decoded-frame hard limits stay fixed.

### A shut-down engine is never revived

`attach(displayLayer:)` guards on `shutdownRequested`, not on an empty
renderer: `finishRendererShutdown` nils `videoRenderer`, so emptiness alone
let a retired engine through. SwiftUI does re-mount the player surface after a
failed playback, and its `makeUIView` attaches unconditionally. A revived
engine registers a renderer set it can never detach (`shutdown` returns early
once requested) and starts a **second demux loop**, which for a transcode is a
second server job nobody stops. The stale renderer entry is process-global, so
the next title waited the full 15 s retirement timeout.

Do not clear the lifecycle counters in `deinit` instead: renderer removal is
asynchronous and outlives the Swift object, so only AVFoundation's completion
can balance it, or the lifecycle bench can no longer see a leak.
`debug.playbackLifecycleLog` prints each lifecycle event with the engine id.

### Audio renderer failure

- `WasFlushedAutomatically` and `OutputConfigurationDidChange` are
  recoverable: both reseek from the playhead.
- A hard failure posts no notification. It shows only in the KVO-observable
  `status` ("terminal status from which recovery is not always possible").
  Unobserved, a failed renderer plays the film in silence and reports nothing.
- The KVO observation hops to the main actor rather than using
  `MainActor.assumeIsolated`, because KVO fires on whichever thread changed
  the property, and CoreMedia does not change it on the main thread.
- Recovery means replacement. It shares one path with the media-services reset.
  `AudioRendererReplacement` encodes the difference: after a reset playback
  stays paused (Apple requires a viewer action to resume); after a
  self-failure it resumes. Neither un-pauses a viewer who paused on purpose:
  the refill goes through `seek`, and `beginPlayback` honours `isPaused`.
- The video renderer stays on the synchronizer throughout, so only a few
  hundred milliseconds of audio are lost.
- If the swap itself fails, playback has no audio path and reports
  `.delivery` (see [Stream recovery](stream-recovery.md)).
- Testing this needs an injected failure; a renderer cannot be made to report
  `.failed` on demand. `audioRendererRecoveryCount` and
  `mediaServicesResetRecoveryCount` are counted separately, so a replacement
  leaves a trace in a host's diagnostics.

### Picture in Picture and AirPlay

PiP uses `AVPictureInPictureController.ContentSource` over the existing
`AVSampleBufferDisplayLayer`, with an
`AVPictureInPictureSampleBufferPlaybackDelegate` whose play, pause and skip
callbacks drive the same `SampleBufferPlayerEngine`. iOS exposes the system
`AVRoutePickerView` for AirPlay. A host declares
`AVInitialRouteSharingPolicy=LongFormVideo` and the audio background mode in
its own Info.plist.

### Video output suspension

Keeps audio playing while a host stops showing video, such as an iOS app in
the background.

- `setVideoOutputSuspended(true)` flushes the video renderer, intake and queue
  on the pump queue. The demux loop discards the video stream inside
  libavformat (`FFmpegDemuxer.setVideoDiscarded`), and the software decode
  stage resets, so nothing decodes and no GPU work runs.
- Audio, the synchronizer clock, the time observer, subtitles and the finish
  boundary carry on.
- Priming, starvation detection and stall recovery treat a suspended picture
  as a finished video queue, so a stall while suspended recovers on audio
  alone.
- Lifting the suspension seeks to the current position, which restarts video
  on a keyframe with a fresh VideoToolbox session that replaces any the system
  invalidated meanwhile.
- A successor engine started while the previous one was suspended inherits
  the suspension.

## Display mode matching (tvOS)

The engine publishes a `DisplayMatchRequest`: the video's tagged
`CMFormatDescription` plus its frame rate, once the demuxer knows the stream.
The host applies it to a window's `AVDisplayManager.preferredDisplayCriteria`
and clears it on exit. The system's Match Content setting (Settings → Video
and Audio) still decides; with it off, criteria are ignored. The simulator has
no display modes, so there it is a no-op.

Matching is not cosmetic. Without it the display idles at 60 Hz in the UI's
range, and the compositor cadence-converts and tone-maps every frame. Full
3840×2160 HDR10 titles dropped frames that way while a 3840×1600 encode of the
same codec, range and bitrate played clean. With matching, the original 4K
HDR10 failure and Snowden's 610 s stress scene both measured zero loss on
hardware.

## Debug playback HUD

The engine emits the raw material for a host's diagnostic overlay; it draws
none itself.

- Every video-performance poll carries `VideoPerformanceSnapshot.droppedFrames`
  and `.corruptedFrames`, with `.totalFrames`, `.optimizedCompositingFrames`
  and `.accumulatedFrameDelay`.
- A "Video Frame Loss" signpost fires on every increase, with the dropped and
  corrupted deltas and totals, total frames, position, video and audio queue
  depths and the stall count, so a trace can tell decoder pressure from
  starvation.
- Other signposts in the same `PlaybackPerformance` category: "Renderer
  Attach", "Playback Cushion Ready", "Playback Stall", "Playback Stall
  Reprime", "Renderer Recovery", "Renderer Teardown", "Demux Close", "Audio
  Timestamp Gap" and the lifecycle events. Capture them with Instruments'
  **Points of Interest** template. All ship in Release, because real Apple TV
  hardware only runs Release.

An overlay composited over the video costs frames itself: one debug HUD
measured 4–5 drops on a 4K stress scene with it on and zero with it off. Use
signposts or console output, overlay off, for a final frame-loss verdict.

**Frame droppability is opt-in metadata.** Per `CMSampleBuffer.h`, a frame is
droppable only if `kCMSampleAttachmentKey_IsDependedOnByOthers` is present and
false. Marking non-reference frames `false` lets the renderer's pre-decode
dropper take them: 67% of the stream on a title that lost 10.7% at a matched
display rate with full queues. So the engine sets `IsDependedOnByOthers` true
on reference frames and leaves it absent otherwise. `debug.markDroppableFrames`
restores the marking for a hardware A/B. Do not trust a simulator A/B here: the
pre-decode dropper does not engage at 60 Hz with software decode.
