# Changelog

Versions follow [semantic versioning](https://semver.org): a breaking change
to anything `public` is a major bump. A type is public if a host can name it
or reach it from one it can.

`scripts/publish-release.sh` takes each release's notes from its entry here.
Write them for someone adopting or upgrading the package: one short bullet
per change, grouped under Added, Changed, Removed and Fixed.

## 1.1.2

September 2026. No API change; upgrading is a version bump. `Libass` is
rebuilt from the same library versions.

### Fixed

- Styled subtitles keep to a memory budget. Each libass renderer caches at
  most 2,000 glyphs and 24 MB of bitmaps instead of libass's desktop
  defaults, and a file's attached fonts are kept up to 64 MB in all; a font
  past that is skipped and falls back to CoreText.
- Choosing a subtitle track no longer blocks the main thread while libass
  starts, copies the fonts and parses a sidecar, or while the previous
  renderer finishes a frame. The plain text stays hidden meanwhile, so it
  never flashes up unstyled.
- ASS drawings (`\p1` … `\p0`) no longer reach `currentSubtitleText` or the
  fallback cues as vector commands, and a signs-only sidecar made of drawings
  loads for libass instead of being rejected as empty.
- `Libass` no longer imports `fstat`: FreeType reads fonts through stdio and
  HarfBuzz is built without mmap, so neither calls a file-timestamp API
  covered by the privacy manifest. libavformat and libavutil still do, so a
  host's `FileTimestamp` declaration stays.

## 1.1.1

September 2026. No API change and no change to the libraries; upgrading is a
version bump.

### Fixed

- A bounded download (artwork, trickplay tiles, sidecar subtitles) that is
  redirected to another host no longer carries the original request's
  credential headers there. URLSession drops `Authorization` itself but
  forwarded any other header, such as a forward-auth proxy's service token
  from `MediaRequestAuthorization.additionalHeaders`. Only `Accept`,
  `Accept-Language`, `Accept-Encoding`, `User-Agent`, `Range`, `If-Range`
  and `Cache-Control` now follow a redirect off the host.

## 1.1.0

September 2026. Adds API and one native library, `Libass`; nothing is removed
or changed, so upgrading is a version bump. A host that credits its
dependencies adds libass, FreeType, FriBidi and HarfBuzz
(`Artifacts/Libass.README.md` has the licences).

### Added

- Styled ASS/SSA subtitles through libass 0.17.5, with FreeType, FriBidi and
  HarfBuzz: named styles, karaoke, `\move`, `\fad`, clips, rotation, borders
  and drawings, in the fonts the file carries as Matroska attachments, then
  CoreText's. Embedded tracks and sidecars alike. Frames arrive through
  `currentSubtitleImages`, as PGS bitmaps do, so an overlay that draws those
  needs no change; the text still feeds `currentSubtitleText`.
- `EngineTuning.rendersStyledSubtitles`, on by default. Off falls back to the
  engine's own cue renderer.
- `MediaRequestAuthorization.additionalHeaders`, for a server behind a
  forward-auth proxy (Cloudflare Access, Authelia, Authentik). They go with
  the credential to the server's origin only, and `remove(from:)` takes every
  one off a request that leaves it.
- 10-bit H.264 (High 10) decodes in software, since no Apple hardware decoder
  accepts it. It is recognised from the stream itself, so one whose metadata
  names no profile no longer reaches VideoToolbox and fails.
- A `styledSubs` field on the bench line: libass's render and composite cost
  per changed frame.
- Releases attach FriBidi's corresponding source, as they do FFmpeg's.

### Fixed

- ASS and SSA sidecar files load. They were rejected as unsupported; their
  dialogue now parses with the same subset as embedded events.

## 1.0.12

September 2026. No API change and no change to the libraries; upgrading is a
version bump.

### Fixed

- MPEG-TS with AAC plays. ADTS AAC, which carries no AudioSpecificConfig, is
  decoded here instead of passed to CoreAudio, which never played it: the
  clock waited on the audio and playback stalled a second in, buffering, with
  no error. Decoded here, it also follows the stereo and 5.1 changes
  broadcast streams make.
- Software-decoded video (VP9, AV1 without AV1 silicon, MPEG-2, VC-1, MPEG-4,
  interlaced H.264) that changes size mid-way, as broadcasts do between SD
  and HD, keeps playing. The decoder rebuilds its output for the new size in
  the mode chosen at open; a new size used to be `.undecodable`.
- `videoSize` follows a decoded stream that changes size, so subtitles are
  laid out against the new picture. Progressive H.264 reaches the renderer
  compressed and keeps the size read at open.

## 1.0.11

September 2026. No API change and no change to the libraries; upgrading is a
version bump.

### Fixed

- A short network drop no longer ends playback. Transient faults (a dropped
  link, a 5xx, 408 or 429, the idle timeout) are retried for up to 30 s from
  the first failure, at 0.25, 0.5, 1 and then 2 s apart, while buffered media
  plays; three retries used to run out in under two seconds. Proven against a
  scripted outage, not a real one on hardware.
- A read that gave up left its failed request behind, so the demuxer's own
  retries rethrew at once instead of reaching the network again. Each retry
  now starts a fresh request.
- The playback cache retries a busy server (a 5xx, 408 or 429) instead of
  reporting it as a server without range support.
- A failed seek is tried once more before it is reported, unless playback
  closed or a newer seek replaced it.
- Audio the engine decodes itself (TrueHD, DTS, FLAC, Opus and the like) keeps
  its format and duration when the stream changes sample rate or channel
  layout mid-way. A 5.1-to-stereo change used to crash, and a lower-rate
  stretch played fast. AAC, AC-3 and E-AC-3 pass through to CoreAudio and are
  unchanged.

## 1.0.10

September 2026. No API change; the FFmpeg libraries are rebuilt from a newer
point release. Upgrading is a version bump.

### Changed

- FFmpeg 8.1.3, up from 8.1.2: about 270 upstream fixes on the same ABI,
  mostly hardening against malformed input (HEVC, interlaced H.264, MP4,
  MPEG-TS, PGS subtitles, Dolby Vision metadata) and an arm64 fix in
  libswresample. Decoded output is bit-identical to 8.1.2 on the parity
  fixtures, and frame loss on the Apple TV 4K (3rd gen) is unchanged.
- 8.1.3 opens HLS child playlists through the same protocol check as media
  segments. The engine's HLS patch already recognises `http(s)` there, so
  transcodes play as before.

## 1.0.9

September 2026. No API change and no change to the libraries; upgrading is a
version bump.

### Fixed

- A native Dolby Vision profile 5 or 8 frame without its RPU gets the previous
  frame's, as converted profile 7 frames already did. VideoToolbox refused such
  a frame and every picture referencing it, and a clip missing one RPU in four
  for ten seconds lost 223 of 755 pictures; it now shows all of them. The HUD
  and the bench line count the repeats.

## 1.0.8

September 2026. No API change and no change to the libraries; upgrading is a
version bump.

### Fixed

- A damaged picture in progressive H.264 no longer ends direct play. The
  renderer reports it and decodes on from the next keyframe; the engine used
  to report the first failure as `.undecodable`.
- A packet the software decoder rejects as invalid data (AV1 in software,
  VP9, MPEG-2, VC-1, interlaced H.264) is dropped instead of failing the
  stream.
- More of VideoToolbox's one-picture faults are dropped rather than judged:
  missing references and unknown decoder errors from the decode call, and
  CoreMedia's malformed-sample errors.
- A decoder that was removed, lost its connection or ran out of memory is
  rebuilt instead of reported as `.undecodable`. At open, the engine tries once
  more before it gives up.
- A stream that has already decoded keeps that standing across seeks, so a
  damaged picture just after one is dropped. Damage right after a seek is
  still judged within about two seconds.

## 1.0.7

September 2026. No API change and no change to the libraries; upgrading is a
version bump.

### Fixed

- A Dolby Vision profile 7 remux whose frames lose their RPU partway through
  keeps playing. Such a frame, or one whose RPU fails to convert, is given the
  previous frame's converted RPU. VideoToolbox used to refuse it with -12704,
  which was reported as `.undecodable`, and a host's ladder fell back to a
  transcode at the same point on every play. The HUD and the bench line count
  the repeats.

## 1.0.6

September 2026. No API change and no change to the libraries; upgrading is a
version bump.

### Changed

- 4K software decode (AV1, VP9) queues at most twelve decoded 10-bit frames,
  about 300 MB, down from thirty. On an Apple TV 4K (3rd generation) a 4K
  AV1 title peaks about 430 MB lower, with no more dropped frames. 1080p and
  hardware decode are unchanged. `-debug.softwareDecodedQueueFrames <n>`
  overrides it for measurement.

### Fixed

- A run of pictures VideoToolbox rejects in the middle of a stream that
  otherwise decodes is dropped instead of being reported as `.undecodable`.
  The picture holds briefly and direct play continues, where a host's ladder
  used to fall back to a transcode. Bad data from the first pictures, or a
  run longer than a ten-second group of pictures, is still a verdict.

## 1.0.5

September 2026. No API change and no change to the libraries; upgrading is a
version bump.

### Added

- Every release attaches FFmpeg's complete corresponding source: upstream's
  tarball, the patch and the build script with its configure records.
  Releases from 1.0.0 on carry it too.

### Fixed

- `Libdav1d.xcframework` ships dav1d's licence, and `Libdovi.xcframework`
  ships a notice covering libdovi, the Rust crates it links and the Rust
  standard library.
- The FFmpeg build script no longer records its work directory in the
  configure line the libraries embed.

## 1.0.4

September 2026. No API change; upgrading is a version bump.

### Fixed

- A Matroska file whose header rounds the frame duration to the millisecond
  (23.976 fps written as 42 ms) plays at the standard rate: the display
  matches it and frames keep an even cadence, instead of judder at 60 Hz.

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
