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
artifacts. libavformat is built by this repository without its network stack,
making it LGPL-2.1-or-later; the three MPVKit binaries keep upstream's
version3 election and are LGPL-3.0-or-later. dav1d and uavs3d are BSD, lcms2
is MIT, libdovi is MIT.

Provenance and rebuild instructions sit beside the artifacts, in
[`Libavformat.README.md`](Artifacts/Libavformat.README.md) and
[`Libdovi.README.md`](Artifacts/Libdovi.README.md).

## Documentation

Start with the [documentation index](docs/README.md), then [coding
standards](docs/standards.md) and [the engine guide](docs/engine.md). The
[engineering notes](docs/reference/README.md) carry the mechanism and the
measurements behind the contracts.

[Contributing](CONTRIBUTING.md) has the build and test commands and the
repository conventions; [security reports](SECURITY.md) go privately by email
rather than into an issue. Taking part here means keeping to the [Code of
Conduct](CODE_OF_CONDUCT.md).
