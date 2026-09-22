# Lagoon Engine

A sample-buffer media playback engine for iOS and tvOS. Swift package, no
`AVPlayer`, no third-party Swift dependency.

It exists because `AVPlayer` will not play a great deal of what people
actually have. This reads the container itself with FFmpeg, decides per track
whether the hardware will take the bitstream, and feeds
`AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer` under an
`AVSampleBufferRenderSynchronizer`.

It was extracted from [Lagoon](https://github.com/helop-ou/lagoon), a Jellyfin
client, and carries none of it: no server, no accounts, no user interface. You
hand it a URL and track metadata, and you get a picture.

## What it plays

MKV, WebM, MP4, MOV, AVI, MPEG-TS and MPEG-PS containers, plus Blu-ray and DVD
disc images. HEVC, H.264, AV1, VP9, VC-1, WMV3, MPEG-2 and MPEG-4 Part 2,
including interlaced H.264 and MPEG-2 through the software decoder. HDR10, HLG
and Dolby Vision, including dual-layer profile 7 converted to 8.1 in flight.
Dolby Atmos passed through; TrueHD, DTS, FLAC and ALAC decoded to lossless
PCM. Embedded, PGS, VobSub, DVB and external subtitles.

Hardware decode through VideoToolbox where the hardware takes the bitstream,
and libavcodec where it does not.

## Requirements

iOS 26 and tvOS 26, Xcode 26.6. Apple silicon to build the native libraries.

## Adding it

```swift
.package(url: "https://github.com/helop-ou/lagoon-engine", from: "0.1.0")
```

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "LagoonEngine", package: "lagoon-engine"),
])
```

The package carries its own FFmpeg build, so there is nothing else to fetch or
configure.

## Using it

Make an engine, give it somewhere to draw, tell it what to open, and play.

```swift
import AVFoundation
import LagoonEngine

let engine = SampleBufferPlayerEngine()

// The engine draws into a layer you own and place in your view hierarchy.
let displayLayer = AVSampleBufferDisplayLayer()
engine.attach(displayLayer: displayLayer)

// Called once the first frame is on screen.
engine.onPlaybackStarted = { print("playing") }

// Called when the engine gives up. `cause` is either .undecodable — this
// device cannot decode these samples, only a re-encode would help — or
// .delivery, meaning the same media might play if fetched another way.
engine.onError = { failure in
    print(failure.cause, failure.message)
}

engine.prepare(
    url: url,
    startSeconds: 0,
    initialAudioOrdinal: nil   // nil lets the container decide
)
engine.play()
```

`prepare` returns immediately; opening and decoding happen on their own
queues. Everything else is what you would expect: `pause()`, `seek(to:)`,
`setRate(_:)`, `selectAudioTrack(id:)`, `selectSubtitleTrack(id:)`, and
`shutdown()` when you are done. Read `audioTracks` and `subtitleTracks`
once playback has started to see what the file offers.

### What it plays

[docs/codec-support.md](docs/codec-support.md) is the generated list: which
video and audio codecs decode, whether each reaches VideoToolbox or
libavcodec, how Dolby Vision and HDR10 are carried, and what is
deinterlaced. It is rendered from the same table the routing code is
tested against, so it cannot promise something the engine refuses.

### Buffering ahead

Give the media a name and say how it is delivered, and the engine puts a
byte cache in front of it: a sparse file it fills ahead of the playhead
once the picture is up, paced so foreground reads always get the link
first. A stable file can be cached this way; a segmented manifest cannot,
and asking for one costs nothing.

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

Read `bufferState` for what it is holding — the buffered fraction and the
cached ranges, for a scrub bar. `suspendBufferFill()` and
`resumeBufferFill()` stop and restart the filling without losing it, for
an app going to the background.

If you know what the viewer will play next, `stageSuccessor` opens and
warms a second scope for it while the current one still plays. A later
`prepare` with the same `itemID` and URL promotes what was warmed instead
of starting over. There is one cache in the process: one active scope and
at most one staged successor, whichever engine is playing.

### Fetching media that needs a credential

Pass a `MediaRequestAuthorization` and the engine sends the header with
every request it makes, including HLS playlists and segments. Credentials
never go into a URL and are never logged.

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

### Talking to it through the protocol

`SampleBufferPlayerEngine` conforms to `PlayerEngine`, which is everything
a player UI needs and nothing about FFmpeg. Bind your controls to that
rather than to the class. If you are also drawing a HUD or collecting
crash reports, `PlayerEngineDiagnostics` is the optional second surface
carrying queue depths, frame counters and decode details.

Diagnostics are off unless you ask for them — install a sink with
`EngineDiagnostics.use(_:)`. The default discards everything.

## Building

```
xcodebuild -scheme LagoonEngine -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme LagoonEngine -destination 'generic/platform=iOS Simulator' build
```

One at a time — they share derived data, and running both at once makes one
fail without a useful diagnosis.

## Licence

This code is under the **Mozilla Public License 2.0** ([LICENSE](LICENSE)).
Fork it, change it, ship it, publish your changes to the files it covers, and
say where they came from.

The Lagoon name is not part of that grant. Give a fork its own name —
[TRADEMARKS.md](TRADEMARKS.md) explains what is carved out and why.

### Third-party notices

The native libraries carry their own licences, and the texts travel with the
artifacts. The four FFmpeg libraries are built by this repository without
their network stack and are LGPL-2.1-or-later. dav1d and uavs3d are BSD,
lcms2 is MIT, libdovi is MIT. Everything but libdovi is built here from
checksum-pinned upstream source, and nothing is downloaded when the package
resolves.

Provenance and rebuild instructions sit beside the artifacts, in
[`FFmpeg.README.md`](Artifacts/FFmpeg.README.md) and
[`Libdovi.README.md`](Artifacts/Libdovi.README.md), and in the header of each
`scripts/build-*` script.

## Documentation

Start with the [documentation index](docs/README.md), then [coding
standards](docs/standards.md) and [the engine guide](docs/engine.md). The
[engineering notes](docs/reference/README.md) carry the mechanism and the
measurements behind the contracts.

[Contributing](CONTRIBUTING.md) has the build and test commands and the
repository conventions; [security reports](SECURITY.md) go privately by email
rather than into an issue. Taking part here means keeping to the [Code of
Conduct](CODE_OF_CONDUCT.md).
