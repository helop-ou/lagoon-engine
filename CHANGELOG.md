# Changelog

Versions follow [semantic versioning](https://semver.org): a breaking change
to anything `public` is a major bump. A type is public if a host can name it
or reach it from one it can.

`scripts/publish-release.sh` takes each release's notes from its entry here.
Write them for someone adopting or upgrading the package: one short bullet
per change, grouped under Added, Changed, Removed and Fixed.

## 1.0.3

September 2026. No API change; upgrading is a version bump.

### Fixed

- After a seek, a packet dropped on the way to the first decodable picture no
  longer sets the frame grid that the following pictures snap to.

### Changed

- Source comments and docs are shorter, and the README's install snippet
  asks for `1.0.0` or later.

## 1.0.2

September 2026. No API change; upgrading is a version bump.

### Changed

- Every native library is now built by this repository from checksum-pinned
  upstream source. `Package.swift` has no remote binary targets, so resolving
  the package downloads nothing.
- All four FFmpeg libraries are LGPL-2.1-or-later, and the build fails if that
  changes. Notices that listed FFmpeg under LGPL-3.0 can say LGPL-2.1-or-later.
- libavcodec includes FFmpeg's aarch64 dotprod and i8mm kernels, picked at
  runtime on chips that support them.
- `av_version_info()` reads `8.1.2` rather than `n8.1.2`.
- Build scripts: `scripts/build-ffmpeg.py` replaces `build-ffmpeg-format.py`,
  and `build-lcms2.sh` and `build-uavs3d.sh` are new.

### Removed

- Vulkan, libplacebo, libass and libswscale, which the engine never used.
- The FFmpeg internal headers MPVKit shipped (`libavutil/internal.h` and its
  neighbours, `libavcodec/mathops.h`, `libavformat/os_support.h`). A host that
  imported one directly needs to stop.

Playback is unchanged: the codec set is the same, and test fixtures decode
bit-identically on the old and new libraries.

## 1.0.1

September 2026. No API change; upgrading is a version bump.

### Changed

- `Libavformat.xcframework` is rebuilt from FFmpeg n8.1.2 without downloading
  MPVKit. The codec selection is committed in the repository and the headers
  come from the FFmpeg source being built. Selections and headers are
  identical to 1.0.0.

### Fixed

- `CONTRIBUTING.md` no longer says to run `swift build` and `swift test`,
  which cannot work on macOS. Build and test against an iOS or tvOS simulator.

## 1.0.0

September 2026. The first tagged release.

### Added

- Demux, decode, render, queues, subtitles, the byte-source cache and the
  vendored FFmpeg build, extracted from the Lagoon app. Nothing in the package
  knows about Jellyfin, accounts or a branded interface.
- `PlayerEngine`, the playback contract: picture, clock, track selection and a
  verdict when playback fails. `SampleBufferPlayerEngine` implements it.
- `PlayerEngineDiagnostics`, an optional surface for queue depths, renderer
  counters and the decode trace.
- `prepare` takes a URL, an item identifier and a `MediaDelivery`. The engine
  decides on caching itself, fills ahead of the playhead, and warms the next
  item. `bufferState` drives a scrub bar.
- `EngineTuning` for decode experiments, measurement switches and cache
  overrides. Everything defaults to off.
- `EngineDiagnostics.use` for receiving the engine's events and incidents.
  Without a sink they are discarded.
- `EngineVersion`, carrying the package and libavformat versions.
- libavformat built without its network stack (HTTP goes through URLSession),
  and dav1d built with its assembly kept. See the README for the licence
  position and `Artifacts/` for each framework's provenance.
