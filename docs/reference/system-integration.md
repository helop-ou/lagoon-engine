# System integration

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [engine guide](../engine.md) and the
[notes index](README.md).

## System media integration

The engine owns the system behavior AVPlayer would otherwise supply, without
adding a second player to get it:

- `PlaybackAudioSession` activates `.playback` / `.moviePlayback`, enables
  multichannel content, uses `.longFormVideo` on iOS, and deactivates with
  `notifyOthersOnDeactivation` when playback ends. Interruption callbacks are
  idempotent: they resume only if the item was playing and the system sets
  `shouldResume`. Route changes pause when a personal output — wired,
  Bluetooth, or AirPlay — disappears, but not on tvOS HDMI mode changes. A
  media-services reset re-establishes the category and active session.
- **Audio spatialization**. One factory,
  `SampleBufferPlayerEngine.makeAudioRenderer`, builds every audio renderer,
  so a replacement after a failure or a reset sounds identical to what it
  replaced. Apple's two players disagree on the spatialization default:
  `AVPlayerItem` documents `monoStereoAndMultichannel` for video, but
  `AVSampleBufferAudioRenderer` documents — and runtime confirms —
  `multichannel` alone. Left alone, a stereo soundtrack that AVPlayer would
  spatialize on AirPods plays flat, true of a lot of television, anime and
  older film. The property only grants permission: the viewer's Spatial Audio
  setting still decides, and it changes nothing over HDMI to a receiver. A
  test pins both defaults, so a future SDK that closes the gap fails it, and
  the override can go.
- **Playback speed** is `PlaybackRatePolicy`: a fixed envelope from 0.5× to
  2×, with a `supported` set of six stops (0.5, 0.75, 1, 1.25, 1.5, 2) for a
  stepped control. `clamped(_:)` holds any input inside that envelope,
  however it was produced. `stepped(from:by:)` finds the next stop in either
  direction and clamps at both ends rather than wrapping — a `+` that jumped
  from 2× to 0.5× would read as a bug — and starts from the nearest stop
  rather than assuming the current rate is already one of the six, because
  the engine accepts any finite value inside the envelope and a system
  integration such as Remote Command Center can hand it something like 1.1.
  `effectiveRate(userRate:correction:)` layers a second multiplier — a
  drift-correction nudge, not a second speed control a viewer chose — into
  the same envelope, so everything downstream scales by one number regardless
  of where it came from. `title(_:)` writes a rate with no trailing zeros and
  a multiplication sign, and `identifier(_:)` gives it a stable identifier
  for accessibility and UI tests, so every place a host displays or tests a
  rate uses the same string.

  Pausing, seeking, buffering, renderer recovery, delivery fallback and
  handoff to a successor engine all preserve the rate. Every audio renderer
  uses the time-domain pitch algorithm, including after a media-services
  reset, so a faster or slower rate never changes pitch. Stall recovery, the
  delivered-PTS margin, initial priming and demux watermarks scale their
  media-time cushion by rate but keep the decoded-frame hard limits fixed.
- **An engine that has shut down must never be revived**.
  `attach(displayLayer:)` guards on `shutdownRequested`, not just on an empty
  renderer. `finishRendererShutdown` nils `videoRenderer`, so emptiness alone
  let a retired engine through — and SwiftUI *does* re-mount the player
  surface after a failed playback, whose `makeUIView` attaches
  unconditionally. The retired engine then re-registered a renderer set it
  could never detach, because `shutdown` early-returns once requested, and
  started a **second demux loop** that reopened the stream — for a transcode,
  a second server-side ffmpeg job nobody would ever stop. The stale renderer
  entry is process-global, and whatever starts the next title waits on
  `PlaybackLifecycleDiagnostics.waitForMediaResourcesToRetire`, so one failed
  title delayed the next by its full 15 s timeout — long enough that a host
  has to decide what to tell the viewer while it waits. Clearing the counters
  in `deinit` was deliberately not tried: renderer removal is asynchronous
  and outlives the Swift object, so only the real AVFoundation completion can
  balance it, or the lifecycle benchmark could no longer see a leak. Traced
  with `debug.playbackLifecycleLog`, printing each lifecycle event with the
  engine id — the ids are what made "the same engine attached twice" visible.
- **Audio renderer failure**. An audio renderer posts two *recoverable*
  notifications — `WasFlushedAutomatically` and `OutputConfigurationDidChange`
  — and both reseek from the playhead. Hard failure posts none: Apple exposes
  it only through the KVO-observable `status`, documented as "terminal status
  from which recovery is not always possible." Unobserved, a failed renderer
  kept the film playing in silence, with nothing reported anywhere. The
  observation hops to the main actor instead of `MainActor.assumeIsolated`,
  unlike the notification blocks, because KVO delivers on whichever thread
  changed the property, and a CoreMedia-owned renderer does not change it on
  the main one. Recovery means replacement — the object cannot be revived —
  sharing one path with the media-services reset, which needs the same swap.
  The two differ only in what the viewer is owed after, which
  `AudioRendererReplacement` encodes: a reset stays paused, since Apple
  requires an explicit viewer action before resuming, while a self-failed
  renderer resumes, since nothing the viewer did caused it. Neither un-pauses
  a viewer who paused on purpose: the refill goes through `seek`, and
  `beginPlayback` honours `isPaused`. The video renderer stays attached to
  the synchronizer throughout, so only a few hundred milliseconds of audio
  are lost, not the film. If the swap itself fails, playback has no audio
  path, and the failure is reported as `.delivery` — the same verdict a
  broken container or transport produces (see
  [Stream recovery](stream-recovery.md)). Exercising this path deliberately
  requires injecting a renderer failure, since a renderer cannot be made to
  report `.failed` on demand. The engine counts audio replacements and
  service resets separately (`audioRendererRecoveryCount`,
  `mediaServicesResetRecoveryCount`), since otherwise a replacement would
  leave no trace in a host's own diagnostics — which is the point of
  counting it.
- PiP uses `AVPictureInPictureController.ContentSource` over the existing
  `AVSampleBufferDisplayLayer` with an
  `AVPictureInPictureSampleBufferPlaybackDelegate` whose play/pause/skip
  callbacks drive the same `SampleBufferPlayerEngine` — there is no hidden
  AVPlayer. iOS exposes the system `AVRoutePickerView` for AirPlay.
  `AVInitialRouteSharingPolicy=LongFormVideo` and the audio background mode
  need declaring in a host's own Info.plist.
- **Video output suspension** is how the engine keeps audio playing while a
  host stops showing video — backgrounding on iOS being the case that
  motivated it, since nothing about the engine's own state needs to change
  just because a host is no longer visible. `setVideoOutputSuspended(true)`
  flushes the video renderer, intake and queue on the pump queue; the demux
  loop discards the video stream inside libavformat
  (`FFmpegDemuxer.setVideoDiscarded`); and the software decode stage resets,
  so nothing decodes and no GPU work runs while suspended. Audio, the
  synchronizer clock, the time observer, subtitles and the finish boundary
  carry on unaffected. Priming, starvation detection and stall recovery treat
  a suspended picture as a finished video queue, so a stall while suspended
  recovers on audio alone. Lifting the suspension resumes with a seek to the
  current position, restarting video on a keyframe and, through the seek's
  decoder reset, a fresh VideoToolbox session — what a hardware decoder
  invalidated while suspended needs. A successor engine started while the
  previous one was suspended inherits the suspension.

## Display mode matching (tvOS)

A custom player has to do by hand what `AVPlayerViewController` does
automatically: ask the display to match the content. The engine publishes a
`DisplayMatchRequest` — the video's tagged `CMFormatDescription` plus its
frame rate — once the demuxer knows the stream. Turning that into an actual
mode switch is a host's job now: applying it to a window's
`AVDisplayManager.preferredDisplayCriteria`, and clearing it on exit, happens
outside the engine. The system's own tvOS Settings → Video and Audio → Match
Content option remains the authority underneath whatever a host does —
criteria are silently ignored when that system setting is off.

Matching the display is not cosmetic. Without a mode switch, the display
idles at 60 Hz in whatever range the UI runs, and the compositor
cadence-converts and tone-maps every video frame it hands over. That
per-pixel cost has been the standing suspect for hardware frame drops on full
3840×2160 HDR10 titles (Resident Evil 2002 and Snowden among them), while a
3840×1600 letterbox encode at the same codec, range and bitrate class
(Tomorrow War) played clean — a comparison that also cleared decode
throughput, Dolby Vision, bitrate and the audio path as causes. Both the
original 4K HDR10 failure and Snowden's 610 s stress scene have since
measured zero loss in normal viewer mode on hardware once matching reached
the display. The simulator has no display modes at all, so criteria applied
there are a no-op.

## Debug playback HUD

The engine emits the raw material a host's own diagnostic overlay draws
from, rather than drawing one itself. Two counters ride on every completed
video-performance poll — `VideoPerformanceSnapshot.droppedFrames` and
`.corruptedFrames`, alongside `.totalFrames`, `.optimizedCompositingFrames`
and `.accumulatedFrameDelay` — and a "Video Frame Loss" signpost fires on
every increase, carrying the dropped and corrupted deltas and running
totals, the total frame count, playback position, video and audio queue
depths, and the stall count, so a hardware trace can tell decoder pressure
from starvation without a screen recording. It rides alongside a family of
other signposts logged to the same `PlaybackPerformance` category —
"Renderer Attach", "Playback Cushion Ready", "Playback Stall", "Playback
Stall Reprime", "Renderer Recovery", "Renderer Teardown", "Demux Close",
"Audio Timestamp Gap" and the lifecycle events covered above — all
capturable with the Instruments **Points of Interest** template on real
Apple TV hardware; every one intentionally ships in Release, TestFlight
included, since real Apple TV hardware only ever runs Release.

Any diagnostic overlay a host composites directly over the video view has a
real frame cost of its own: a debug HUD built this way once measured 4–5
presentation drops on a 4K stress scene with it on, and zero across repeats
with it off. Prefer signpost or console output with such an overlay disabled
for a final frame-loss verdict.

**Frame droppability is opt-in metadata.** `CMSampleBuffer.h` says, "A frame
is considered droppable if and only if
kCMSampleAttachmentKey_IsDependedOnByOthers is present and set to
kCFBooleanFalse." Absent means not droppable. Marking disposable frames
`false` licenses the renderer's *pre-decode* dropper for every non-reference
frame — 67% of the stream on the title that measured 10.7% steady loss at a
matched display rate with full queues. The engine therefore volunteers
nothing by default: `IsDependedOnByOthers` is true only on reference
frames, absent otherwise. The old marking sits behind
`debug.markDroppableFrames` for a hardware A/B. Never trust a simulator A/B
here: the pre-decode dropper does not engage at 60 Hz with software decode.
