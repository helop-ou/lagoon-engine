# Lagoon Engine

A sample-buffer media playback engine for iOS and tvOS, as a Swift package.
No `AVPlayer`, no third-party Swift dependency.

`AVPlayer` will not play much of what people have. This engine reads the
container with FFmpeg, decides per track whether the hardware takes the
bitstream, and feeds `AVSampleBufferDisplayLayer` and
`AVSampleBufferAudioRenderer` under an `AVSampleBufferRenderSynchronizer`.

It was extracted from [Lagoon](https://github.com/helop-ou/lagoon), a Jellyfin
client, and carries none of it: no server, no accounts, no UI. You hand it a
URL and track metadata, and you get a picture.

## What it plays

MKV, WebM, MP4, MOV, AVI, MPEG-TS and MPEG-PS containers, plus Blu-ray and DVD
disc images. HEVC, H.264, AV1, VP9, VC-1, WMV3, MPEG-2 and MPEG-4 Part 2,
including interlaced H.264 and MPEG-2 through the software decoder. HDR10, HLG
and Dolby Vision, including dual-layer profile 7 converted to 8.1 in flight.
Dolby Atmos passed through; TrueHD, DTS, FLAC and ALAC decoded to lossless
PCM. Embedded, PGS, VobSub, DVB and external subtitles.

VideoToolbox decodes where the hardware takes the bitstream; libavcodec
decodes the rest.

## Requirements

iOS 26 and tvOS 26, Xcode 26.6. Apple silicon to build the native libraries.

## Adding it

```swift
.package(url: "https://github.com/helop-ou/lagoon-engine", from: "1.0.0")
```

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "LagoonEngine", package: "lagoon-engine"),
])
```

The package carries its own FFmpeg build; there is nothing else to fetch or
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

`prepare` returns at once; opening and decoding run on their own queues. The
rest is what you would expect: `pause()`, `seek(to:)`, `setRate(_:)`,
`selectAudioTrack(id:)`, `selectSubtitleTrack(id:)`, and `shutdown()` when you
are done. Read `audioTracks` and `subtitleTracks` once playback has started.

### What it plays

[docs/codec-support.md](docs/codec-support.md) is the generated list: which
codecs decode, whether through VideoToolbox or libavcodec, how Dolby Vision
and HDR10 are carried, and what is deinterlaced. It is rendered from the table
the routing code is tested against, so it cannot promise what the engine
refuses.

### Buffering ahead

Name the media and say how it is delivered, and the engine puts a byte cache
in front of it: a sparse file filled ahead of the playhead once the picture is
up, paced so foreground reads get the link first. A stable file can be
cached; a segmented manifest cannot, and asking costs nothing.

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

- `bufferState` has the buffered fraction and cached ranges, for a scrub bar.
- `suspendBufferFill()` and `resumeBufferFill()` pause and resume filling
  without losing what is cached, for an app going to the background.
- `stageSuccessor` warms a second scope for what plays next. A later `prepare`
  with the same `itemID` and URL promotes it instead of starting over.
- There is one cache per process: one active scope and at most one staged
  successor, whichever engine is playing.

### Fetching media that needs a credential

Pass a `MediaRequestAuthorization`, and the engine sends the header with every
request, HLS playlists and segments included. Credentials never go into a URL
and are never logged.

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

`SampleBufferPlayerEngine` conforms to `PlayerEngine`: everything a player UI
needs and nothing about FFmpeg. Bind your controls to the protocol, not the
class. For a HUD or crash reports, `PlayerEngineDiagnostics` is an optional
second surface with queue depths, frame counters and decode details.

Diagnostics are off by default. Install a sink with
`EngineDiagnostics.use(_:)`.

## Building

```
xcodebuild -scheme LagoonEngine -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme LagoonEngine -destination 'generic/platform=iOS Simulator' build
```

Run them one at a time: they share derived data, and running both at once
fails one without a useful diagnosis.

## Licence

**Mozilla Public License 2.0** ([LICENSE](LICENSE)). Fork it, change it, ship
it; publish your changes to the files it covers, and say where they came from.

The Lagoon name is not part of that grant. Give a fork its own name:
[TRADEMARKS.md](TRADEMARKS.md) explains what is carved out and why.

### Third-party notices

The native libraries carry their own licence texts with the artifacts:

- FFmpeg's four libraries: LGPL-2.1-or-later, built here without their network
  stack.
- dav1d and uavs3d: BSD. lcms2 and libdovi: MIT.

Everything but libdovi is built here from checksum-pinned upstream source, and
nothing is downloaded when the package resolves. Provenance and rebuild steps
are in [`FFmpeg.README.md`](Artifacts/FFmpeg.README.md),
[`Libdovi.README.md`](Artifacts/Libdovi.README.md), and the header of each
`scripts/build-*` script.

## Documentation

- [Documentation index](docs/README.md), then [coding
  standards](docs/standards.md) and [the engine guide](docs/engine.md).
- [Engineering notes](docs/reference/README.md): the mechanism and
  measurements behind the contracts.
- [Contributing](CONTRIBUTING.md): build and test commands, repository
  conventions.
- [Security reports](SECURITY.md) go privately by email, not into an issue.
- Taking part means keeping to the [Code of Conduct](CODE_OF_CONDUCT.md).
