# Using the engine

The [README](../README.md#using-it) has the minimal setup. This guide covers
the rest: what your app sets up around the engine, and what the engine offers
beyond play and pause. Upgrading from 1.x? Start at [Moving from 1.x to
2.0](#moving-from-1x-to-20).

## One engine, one title

```swift
let engine = SampleBufferPlayerEngine()
engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
engine.attach(displayLayer: displayLayer)
engine.play()
```

- `prepare` names the media and returns at once. `attach(displayLayer:)`
  gives the engine its layer. The open starts when it has both, in either
  order, on the engine's own queues.
- `onPlaybackStarted` fires once the first frame is up, and `onError` when the
  engine gives up. Until one of them, `startupPhase` says how far the start
  has got.
- A new engine is not paused, so the title plays as soon as it is ready.
  Call `pause()` before `prepare` to open on the first frame and wait.
  `play()` and `pause()` state what the viewer wants and are safe to repeat.
- `shutdown()` ends it. An engine that was shut down is never used again:
  make a new one for the next title. `shutdown()` returns at once and the
  decoders and renderers retire behind it. Before you start a replacement,
  await `waitForMediaResourcesToRetire(timeout:)` on the old engine, so two
  pipelines never overlap.
- The engine is main-actor API apart from the members marked `nonisolated`.
  Its callbacks arrive on the main actor.
- The callbacks are stored closures. Capture the engine weakly in them, and
  hold it weakly from anything SwiftUI retains, or it outlives its playback.

## The class and the protocol

`SampleBufferPlayerEngine` conforms to `PlayerEngine`: everything a player UI
needs and nothing about FFmpeg. Bind your controls to the protocol, not the
class. The code that owns a playback uses the class, because `prepare`,
`attach`, `shutdown`, the callbacks, `startGate` and the cache calls exist only
there.

For a HUD or crash reports, `PlayerEngineDiagnostics` is an optional second
surface with queue depths, frame counters and decode details.

## What your app sets up

The package configures nothing in your app. The engine never touches the
audio session, and it does not watch your app's lifecycle. These are yours:

- **The audio session.** Set a playback category
  (`AVAudioSession.Category.playback`, mode `.moviePlayback`) and activate the
  session before playback. Deactivate it when playback ends. Without a
  playback category, sound follows the silent switch and stops in the
  background. For surround over HDMI or AirPlay, the session must allow
  multichannel content.
- **Interruptions and route changes.** The engine does not observe them.
  Call `pause()` when an interruption begins or a personal output goes away,
  and `play()` when the system says to resume.
- **A media-services reset.** When
  `AVAudioSession.mediaServicesWereResetNotification` arrives, set the session
  up again, then call `recoverAfterMediaServicesReset()`. The engine replaces
  its audio renderer and stays paused until you call `play()`.
- **Background audio.** Declare the `audio` background mode in your
  Info.plist if playback should continue there. For AirPlay, also declare
  `AVInitialRouteSharingPolicy` as `LongFormVideo`.
- **Going to the background.** Call `setHostInBackground(true)` on every
  move to the background and `false` on every return, whatever is still
  showing. The system can take a decode session there, and the engine then
  holds video until the app returns instead of failing playback. Call
  `setVideoOutputSuspended(true)` when nothing shows the picture any more:
  audio, the clock and subtitles carry on, and nothing decodes video.
  `false` brings the picture back without touching the sound.
  `suspendBufferFill()` and `resumeBufferFill()` do the same for the byte
  cache.
- **Picture in Picture.** Build an `AVPictureInPictureController` over the
  same display layer, with your own playback delegate driving `play()`,
  `pause()` and `seek(by:)`. See [subtitles in Picture in
  Picture](#subtitles-in-picture-in-picture).
- **The display mode on Apple TV.** See [the start](#the-start).

## Tracks

`audioTracks` and `subtitleTracks` are filled when the streams are known,
before the first frame. Observe them instead of reading them once: a subtitle
you add with `addExternalSubtitle(_:)` joins the list later, and so do closed
captions.

- Pass a track's `engineID` back to `selectAudioTrack(id:)` or
  `selectSubtitleTrack(id:)`. The id is opaque. It is not an index into the
  list. `selectSubtitleTrack(id: nil)` turns subtitles off.
- **Closed captions** carried in the video (CEA-608) are found only when the
  first caption is read, which can be minutes in. The track then appears
  last in `subtitleTracks`, with the id `PlayerTrack.closedCaptionsEngineID`
  and `isHearingImpaired` set. Its name is "Closed Captions". To translate
  it, add that key to your app's string catalog.
- `onTrackSelectionChanged` fires when a selection changes.
- External subtitle files go into `prepare(externalSubtitles:)`, or into
  `addExternalSubtitle(_:)` while a title plays. `subtitleLoadState` says
  whether one is loading or failed, and `retrySubtitleLoad()` tries again.

## Buffering ahead

Name the media and say how it is delivered, and the engine puts a byte cache
in front of it: a sparse file filled ahead of the playhead once the picture is
up, paced so foreground reads get the link first. A stable file can be
cached. A segmented manifest cannot, and asking costs nothing.

```swift
engine.prepare(
    url: url,
    itemID: "episode-412",      // yours; the engine only matches on it
    delivery: .stableFile,
    expectedLength: sizeInBytes, // optional, saves a probe request
    startSeconds: 0,
    initialAudioOrdinal: nil
)
```

- `bufferState` has the buffered fraction and cached ranges, for a scrub bar,
  and the rate the link delivers while busy, to tell a slow link from
  anything else.
- `suspendBufferFill()` and `resumeBufferFill()` pause and resume filling
  without losing what is cached, for an app going to the background.
- `stageSuccessor` warms a second scope for what plays next. A later `prepare`
  with the same `itemID` and URL promotes it instead of starting over.
- There is one cache per process: one active scope and at most one staged
  successor, whichever engine is playing.

## Fetching media that needs a credential

Pass a `MediaRequestAuthorization`, and the engine sends the header with every
request, HLS playlists and segments included. Credentials never go into a URL
and are never logged. A server behind a forward-auth proxy can add the
proxy's headers with `additionalHeaders`. They go to the same origin only.

```swift
engine.prepare(
    url: url,
    startSeconds: 0,
    initialAudioOrdinal: nil,
    authorization: MediaRequestAuthorization(
        origin: serverURL,
        headerName: "Authorization",
        headerValue: token
    )
)
```

## When playback fails

`onError` hands you a `PlaybackEngineFailure`. The engine has already tried
what it can on its own, so this is the point to try something else or tell
the viewer.

```swift
engine.onError = { failure in
    switch failure.transport {
    case .httpStatus(401), .httpStatus(403):
        break   // the credential was refused: sign in again, do not retry
    case .urlError:
        break   // offline, unknown host, timeout: another delivery fails too
    case .httpStatus, nil:
        break   // decide from failure.cause
    }
}
```

- `cause` is the engine's verdict about the samples. `.undecodable` means
  this device cannot decode them, and only a re-encode can help. `.delivery`
  means the container, the transport or a system object failed, and the same
  media may play delivered another way.
- `transport` is what the network last answered when a read failed there:
  `.httpStatus(Int)` or `.urlError(Int)`, an `NSURLErrorDomain` code. A
  refused credential or a lost network fails the same way however the media
  is delivered, so check it before asking for the media again.
- `message` is for the viewer. `detail` is the same failure in codes, for a
  report, and never carries a URL or a file name.

`PlaybackFailureDetail.Stage` names only the stages the engine reports. To
report a failure of your own in the same shape, such as a server refusing
the request before there is anything to open, add a stage in an extension:

```swift
extension PlaybackFailureDetail.Stage {
    static let negotiate = Self(rawValue: "negotiate")
}
```

## The start

`startupPhase` moves through `idle`, `connecting`, `openingContainer`,
`probingStreams`, `priming` and `started`. Show it, or use it to say something
when a server is slow to answer.

`startGate` lets you hold the first start. The engine awaits it once the
first picture is up, with the clock stopped, and starts when it returns.

```swift
engine.startGate = {
    await displaySettled()   // yours, and it must give up after a few seconds
}
```

- Bound your own wait. Playback does not start until the gate returns.
- A seek during the hold starts through the gate again, possibly while your
  earlier call is still waiting. Each call must return on its own.
- Do not capture the engine strongly in the closure.

The reason it exists is the display mode on Apple TV. `displayMatchRequest`
carries the video's format description and frame rate once the streams are
known. Apply it and clear it yourself:

```swift
// tvOS, with AVKit imported
if let request = engine.displayMatchRequest {
    window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(
        refreshRate: request.frameRate,
        formatDescription: request.formatDescription
    )
}
// On exit: window.avDisplayManager.preferredDisplayCriteria = nil
```

The system honours it only with Match Content on in Settings. A mode switch
blanks the panel for about three seconds, and a title that starts meanwhile
loses them. So wait in `startGate` for `AVDisplayManagerModeSwitchEnd`, with
a cap, because that notification does not always arrive. The rate is already
a standard one, and interlaced video asks for its field rate: 50 for 50i.

## Sound

`setAudioShaping(_:)` takes an `AudioShaping`:

```swift
engine.setAudioShaping(AudioShaping(nightMode: true, dialogueBoost: true, channelLimit: .stereo))
engine.setAudioShaping(.off)
```

- `nightMode` brings quiet passages up and loud ones down. `dialogueBoost`
  lifts the centre channel. `channelLimit` downmixes to `.stereo` or
  `.surround`.
- While any of it is on, every audio track is decoded to PCM in the engine.
  AC-3, E-AC-3 and AAC stop passing through compressed, and Dolby Atmos is
  lost. Say so where you offer the setting.
- Set before `prepare`, the title opens with it. Set while playing, it
  applies from the current position with a short re-read, as a seek does.

`setAudioDelay(_:)` moves audio against video, within 5 s either way.
`PlaybackRatePolicy.supported` lists the rates to offer for `setRate(_:)`.

## Subtitles

`currentSubtitleCues` and `currentSubtitleImages` are what to draw now, over
the video, in your own style. Text cues carry their placement, and bitmap and
styled (ASS) tracks arrive as images.

`setSubtitleOffset(_:)` shows subtitles later (positive) or earlier, within
30 s either way. Text, bitmap and styled tracks all move, without a seek.

### Subtitles in Picture in Picture

Picture in Picture shows only the display layer, so your overlay is gone
there. Ask the engine to draw the selected subtitles into the frames
instead:

```swift
engine.setPictureInPictureSubtitles(.standard)   // when Picture in Picture starts
engine.setPictureInPictureSubtitles(nil)         // when it ends
```

- `BurnedInSubtitleStyle` sets the colours, the edge, the background box, the
  font and `relativeSize`, the line height as a fraction of the picture's
  height (0.055 by default). It applies to
  text subtitles. Bitmap and styled tracks keep their own look.
- Clear it with `nil` when Picture in Picture ends, or the subtitles are
  drawn under your overlay as well.
- Turning it on can cost a short rebuffer.

## What the device decodes

`PlaybackCapabilities.current` says what the hardware takes: `hardwareHEVC`,
`hardwareAV1` and `hardwareVP9`. Use it when you tell a server what to send.
HEVC needs the hardware. AV1 and VP9 decode in software without it.
`hardwareVP9` is always false before iOS 26.2 and tvOS 26.2. The [codec
table](codec-support.md) has every codec and its path.

A true is not a promise: a stream the decoder refuses still ends in
`onError` with `.undecodable`.

## Diagnostics

Diagnostics are off by default. Install a sink once, before playback, with
`EngineDiagnostics.use(_:)`. It receives events (`EngineDiagnosticEvent`) and
incidents (`EngineDiagnosticIncident`) with their fields.

Both are open sets: a later release can add values without a major version.
A `switch` over one needs a `default`.

```swift
func record(_ event: EngineDiagnosticEvent, _ fields: [String: DiagnosticValue]) {
    switch event {
    case .playbackStartup: break   // firstByteMs, containerOpenedMs, streamsProbedMs, firstFrameMs
    case .playbackSlowStart: break // nothing came back within a few seconds
    default: break
    }
}
```

`EngineVersion.current` is the version your app resolved, for a report.

## Moving from 1.x to 2.0

What stops compiling:

- **`EngineDiagnosticEvent` and `EngineDiagnosticIncident` are structs, not
  enums.** Add a `default` to every `switch` over them. Their
  `init(rawValue:)` no longer fails, so drop the `if let`, `guard let`, `??`
  or `!` around it. It now accepts any string, so compare against the values
  you know instead of treating a successful init as a known event.
- **`MediaSegment`, `PlayerChapter`, `TrickplaySource`, `TrickplayTile`,
  `PlayerItemInfo` and `NextUpEpisode` are gone.** They described a player's
  screen and one server's segment types, and the engine never read them.
  Declare the ones your app uses in your app.
- **`PlaybackFailureDetail.Stage` is a struct, not an enum, and names only
  what the engine reports.** `negotiate`, `start`, `cache`, `handoff` and
  `unknown` are gone: add the ones your app uses [in an
  extension](#when-playback-fails). Add a `default` to a `switch` over it,
  and drop the `if let` or `??` around its `init(rawValue:)`.

What compiles but behaves differently:

- **A sink receives two more events**, `playbackStartup` and
  `playbackSlowStart`.
- **`subtitleTracks` can grow while a title plays.** Closed captions join it
  when the first one is read, with the id
  `PlayerTrack.closedCaptionsEngineID`. Do not treat an `engineID` as an
  index, and observe the list.
- **Interlaced video plays at field rate.** `displayMatchRequest.frameRate`
  is 50 for 50i and 59.94 for 60i, where it was 25 and 29.97.
  `EngineTuning.deinterlacesAtFrameRate` brings the old behaviour back.
- **`displayMatchRequest.frameRate` is a standard rate.** A container's 23.98
  becomes 24000/1001.
- **A start is presented 0.25 s after the clock is anchored, not 0.1 s.**
- **On an AirPlay route a start is not scheduled.** `play(atHostTime:)`
  starts as soon as the receiver is ready there, not at the instant given.
- **VP9 decodes in hardware where the device has the decoder**, and H.264 is
  decoded ahead by VideoToolbox instead of inside the display layer.
  `videoOutputPathDiagnostic` reports the new paths.
- **Dolby Vision signalling changed for records that cannot be trusted.**
  Profile 8.2 plays its SDR base without Dolby Vision. A profile 8 record
  with a base layer id other than 1, 2 or 4 is signalled by the base layer
  it really has. A profile 5 record over an HDR10 stream is corrected from
  its first RPU.
- **`attach(displayLayer:)` before `prepare` now plays.** In 1.x it opened
  nothing and reported nothing.

What is new, and has a default so your own `PlayerEngine` or
`PlayerEngineDiagnostics` conformance still compiles:

- `PlayerEngine`: `startupPhase`, `audioShaping`, `setAudioShaping(_:)`,
  `subtitleOffset`, `setSubtitleOffset(_:)`,
  `setPictureInPictureSubtitles(_:)`.
- `PlayerEngineDiagnostics`: `demuxReadAheadSeconds`, `demuxReadAheadLimit`.
- `SampleBufferPlayerEngine.startGate`, `PlaybackEngineFailure.transport`,
  `PlaybackCapabilities.hardwareVP9`, `PlayerTrack.closedCaptionsEngineID`,
  `AudioShaping`, `BurnedInSubtitleStyle`, `PlaybackStartupPhase`,
  `PlaybackTransportFailure`, `DemuxReadAheadLimit`.
