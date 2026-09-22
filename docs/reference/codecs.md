# Codec, timing and subtitle details

Playback engineering notes from the September 10, 2026 documentation cleanup.
Start with the [engine guide](../engine.md) and the [notes
index](README.md).

## Codec and timing details

- **Compressed packets stay zero-copy.** Matroska already stores h264 and hevc
  the way CoreMedia wants them, so a demuxed packet becomes a sample buffer
  with no repacking. CoreAudio takes aac, mp3, ac3 and eac3 compressed too.
  ac3 and eac3 describe themselves; aac needs its AudioSpecificConfig passed
  as the magic cookie. Packet cadence prefers FFmpeg's parsed `frame_size`,
  falling back by codec, including 576 samples for MPEG-2/2.5 Layer III at 24
  kHz and below. The CoreMedia block keeps the packet's underlying
  `AVBufferRef` with `av_buffer_ref` and releases it after decode, so each
  packet skips a packet-structure clone and a second allocation plus full
  payload copy. Packet pts, dts and duration convert to `CMTime` in the
  stream's exact rational time base, never round-tripped through floating
  point or a fixed 90 kHz scale.
- **Audio decode.** Codecs CoreAudio won't take compressed — DTS, TrueHD,
  FLAC, Opus, Vorbis, anything with an FFmpeg decoder — go through
  `AudioDecoder`: libavcodec, then swresample, then interleaved Float32 LPCM,
  coalesced to about 2048-sample chunks because TrueHD frames are only 40
  samples each. swresample writes into a growable allocation reused across
  chunks, and the chunk is then **copied** into a CoreMedia-owned block at
  emit; do not remove that copy — the zero-copy handoff that skipped it leaked
  the entire decoded audio stream (see [the decoded-frame memory
  ceiling](frame-loss-bench.md#decoded-frame-memory-ceiling)).
  FFmpeg's native channel-bit order matches CoreAudio's channel bitmap
  bit-for-bit on the first 18 positions, so a native layout mask maps straight
  into the `AudioChannelLayout`.
- **Atmos from E-AC3 JOC: the recipe.** Settled on real hardware on
  2026-08-17, after three failed attempts. When FFmpeg reports
  `AV_PROFILE_EAC3_DDP_ATMOS`, the format description must use the **`'ec+3'`
  media subtype** — Apple's "Enhanced AC-3 with JOC," with no public constant
  — and **`mChannelsPerFrame = 16`**, the HLS `CHANNELS="16/JOC"`
  presentation, plus the synthesized `dec3` box (ETSI TS 102 366 Annex F) as
  magic cookie and extension atom. What does NOT work: plain `ec-3`
  passthrough, and `kAudioChannelLayoutTag_Atmos_9_1_6` alone or combined with
  `ec-3` plus dec3 — both decode only the DD+ core and report "Multichannel".
- **LPCM timing.** Successive LPCM buffers anchor to the sample-exact end of
  the previous one, stamped at the stream's own sample rate, and re-anchor to
  container pts only on jumps past 50 ms. Matroska stamps at 1 ms precision,
  but TrueHD frames are 0.83 ms, and 90 kHz cannot represent 48 kHz
  boundaries. Either mismatch renders as steady clicking.
- **Passthrough audio timing.** The same clicking mechanism hit the
  *compressed* path too. An AAC frame is 1024 samples, 21.33 ms, which
  Matroska's 1 ms stamps cannot represent, so container pts jitters up to
  about 1.7 ms — measured deltas of 21, 22 and 23 ms at roughly 47 packets/s —
  each a discontinuity the renderer renders as crackle. EAC3 was immune,
  because its 1536-sample frame is exactly 32 ms, so only AAC titles crackled
  on hardware. `PassthroughAudioTimeline` chains pts sample-exactly from one
  container anchor, re-anchoring only on forward gaps beyond **half a packet**
  — tight enough that one *missing* packet cannot become a permanent A/V
  offset, which the LPCM path's 50 ms tolerance would have swallowed for every
  passthrough codec. Backward packets beyond that tolerance overlap queued
  audio and are dropped until the container catches up; this is what absorbs
  the measured HLS AAC boundary sequence — four 1-sample packets, then a short
  preroll packet — without pulling the renderer backward. Explicit seeks reset
  the chain. The HUD's `aGaps` counter must read 0 during untouched playback.
- **Video frame-grid timing.** Matroska quantizes video pts to 1 ms, while a
  23.976 fps frame lasts 41.708 ms. `VideoFrameTimeline` snaps each pts to the
  nearest whole-frame step from the previous snapped stamp, using signed steps
  — packets arrive in decode order, so B-frame reordering walks backwards — in
  exact integer arithmetic in the frame rate's own timescale. Stamps beyond a
  5 ms tolerance (VFR, broken mux) pass through untouched and re-anchor.
  Decode stamps stay the container's; they only order the decode. This is a
  scheduling-accuracy invariant, *not* the frame-loss fix: hardware A/Bs had
  the failing title dropping at the same rate with exact and with untouched
  stamps, so do not re-attribute frame loss to timestamp jitter. The HUD's
  `Vtime: grid N/D` line is the gate check.
- **HEVC decode-ahead and presentation order.** The frame loss was isolated to
  handing compressed full-raster 4K Main10 samples straight to the
  sample-buffer renderer. `VideoToolboxDecoder` hardware-decodes HEVC ahead,
  *inside the same Lagoon engine*, and wraps its IOSurface-backed
  10-bit-capable pixel buffers as ready image sample buffers for the renderer.
  Its pool reconciles tvOS 26's `recommendedPixelBufferAttributes` with
  Lagoon's IOSurface and Metal requirements. Pixel format stays unconstrained
  so VideoToolbox preserves native bit depth and colour attachments, and
  ambient viewing environment metadata is restored on decoded output as a
  fallback. Decoder callbacks are not a presentation-order contract, so a
  bounded PTS queue keeps at least six frames — or the larger FFmpeg-reported
  codec delay, capped at 16 — and emits strict display order. Seek recreates
  the decoder and discards the old callback generation; EOF finishes delayed
  frames before waiting. A seek-preroll `kVTVideoDecoderReferenceMissingErr`
  is scoped to that failed access unit: drop the frame, let the valid session
  recover at the next reference picture, and never abort the player. The
  rendered-frame queue's **18-frame high / 12-frame low watermark** bounds a
  0.50–0.75 s cushion at 23.976 fps — enough for high-bitrate input jitter
  without unbounded 4K surfaces. On Apple TV 4K (3rd generation) the original
  4K HDR10 failure went from about 10% loss to **0 / 1462 dropped**, with zero
  stalls and zero audio gaps. The watermark was sized on Snowden's 610 s
  stress scene, which exposes input starvation rather than decode cost. At the
  earlier 12/8 watermark, three hardware runs lost 1.25–1.65% with 3–11 stalls
  and `minQ=0`; the same scene rerun at the 18/12 cushion was **0 / 1438**
  with `minQ=10`. Both figures need the HUD off — the same build measured 5 /
  1445 with the overlay up despite a healthy queue; see the [bench
  procedure](frame-loss-bench.md#frame-loss-bench). No finite
  sub-second cushion can turn an upstream feed running below real time into
  uninterrupted playback: sustained 91 Mbps pulls slowed even format probing
  to 20–40 s, so those cases correctly enter buffering.
- **VC-1 direct play.** Apple exposes no VC-1 VideoToolbox decoder on tvOS,
  but `AVSampleBufferVideoRenderer` accepts ready sample buffers containing
  Core Video image buffers. Lagoon keeps the original MKV and audio stream,
  decodes progressive 8-bit VC-1 through the pinned libavcodec, copies planar
  4:2:0 output into renderer-recommended IOSurface/Metal-compatible NV12
  buffers, carries colorimetry and exact frame timing, and wraps each image
  with `CMSampleBufferCreateReadyWithImageBuffer`. The advertised profile is
  capped at 1080p progressive; anything outside it takes the server transcode
  fallback. Keeping eligible files in one original stream also removes the
  short HLS fragment boundary that caused the reported repeating audio
  cut-outs. The affected VC-1 + AC-3 pairing decodes AC-3 locally to LPCM
  first. This is still Direct Play and deliberately narrow: E-AC-3/Atmos and
  non-VC-1 AC-3 retain compressed passthrough. Chroma interleaving uses an ARM
  NEON C primitive, with a scalar fallback, instead of a per-byte Swift loop,
  and software VC-1 holds a 30/24-frame decoded reserve with a 42-frame hard
  ceiling. Each packet iteration has its own autorelease pool: the demux
  worker is one long-lived dispatch item, so relying on its outer pool
  retained Core Media scratch allocations until dismissal, even though the
  frame queues were bounded.
- **MPEG-4 Part 2 direct play.** The Xvid/DivX AVI envelope rides the same
  libavcodec → Core Video path VC-1 opened, so enabling it was
  `SoftwareVideoDecoder.supports` plus an `avi` container and a bounded
  `mpeg4` profile — no new engine machinery. Simple and Advanced Simple
  Profile are 8-bit 4:2:0 *by specification*, exactly what the software
  decoder accepts, so the pixel-format gate cannot be surprised. AC-3 beside
  this video routes through `AudioDecodePolicy.requiresLocalPCM`, which keys
  on `softwareVideoDecoded` rather than on VC-1, so the pairing that made VC-1
  stutter was already handled. **Packed bitstream** is the one real quirk: old
  DivX/Xvid rips pack two VOPs into one AVI chunk and mark the gap with a
  7-byte "VOP not coded" packet. libavcodec logs `Discarding excessive
  bitstream in packed xvid` and consumes them correctly, with exact frame
  accounting either way. A decode sweep of all 197 AVI titles on the fixture
  server found 29 packed and 1 genuinely damaged file — the server transcode
  hits the same `illegal MB_type` errors, so direct play is not worse — and no
  zero-size packets. The minimum was 7 bytes; a zero-size packet is
  libavcodec's drain signal and would have ended the stream mid-playback. The
  `mpeg4_unpack_bframes` BSF is in the pinned build if a defect surfaces. The
  demuxer has no bitstream-filter plumbing today, and adding it was
  deliberately not done on this evidence.
- **MPEG-2, PCM and DVB subtitles.** The decoders were already in the pinned
  build; the missing piece was the profile that let the server send them.
  Progressive SDR MPEG-2 uses the bounded 8-bit 4:2:0 software path at up to
  1080p, and interlaced MPEG-2 direct-plays too. MPEG program and
  transport-stream, plus VOB containers, are included so DVD and recorded-TV
  sources can reach that path. PCM variants, Blu-ray LPCM and DVD LPCM use the
  libavcodec → Float32 LPCM audio path. DVB bitmap subtitles use the
  paletted-rectangle decoder and overlay that PGS and VobSub already use.
- **Deinterlacing.** The software decode path makes an interlaced frame
  progressive before copying it out, so MPEG-2 no longer has to go to the
  server to be watchable. It is written rather than linked, because
  deinterlacing normally means libavfilter's yadif, and libavfilter is not
  among the pinned artifacts — reaching for it is a dependency decision, not a
  filter call. `Deinterlacer` does the useful half of yadif's spatial pass:
  predict along whichever direction the image runs, and keep the original
  sample wherever the two fields already agree. It gives up yadif's temporal
  half; the per-pixel agreement test stands in for it, so a still shot
  survives at full vertical resolution and only motion is interpolated.
  Measured against yadif on a real interlaced frame: 0.34 levels per pixel out
  of 255, at 1.61 ms per frame at 720x576. Two deliberate details: the frame
  is made writable first, because what the decoder hands over may still be a
  reference frame later pictures are predicted from; and only MPEG-2's
  `IsInterlaced` guard came out of the profile at the time, since every codec
  that decodes in hardware has no stage to hand a field pair to. That guard is
  also what makes a DVD image playable at all: with it in place, a server
  answers an interlaced disc with a transcode, and the image never reaches the
  engine.
- **Interlaced H.264.** H.264's `IsInterlaced` guard is gone too. A 1080i
  broadcast recording (H.264 High, AC-3, MKV) was transcoding on the first
  negotiation for that condition alone, and Sentry showed the server's
  real-time encode stalling on it. The profile cannot say "interlaced only",
  so the split is the demuxer's: `FFmpegDemuxer.isInterlaced(fieldOrder:)`
  reads the field order libavformat probed. Interlaced H.264 goes to
  `SoftwareVideoDecoder` — whose `supports` accepts H.264 only on that route,
  so a failed hardware description for progressive H.264 still fails rather
  than decoding on the CPU — and through the deinterlacer above; progressive
  H.264 stays compressed on VideoToolbox. Unknown field order counts as
  progressive. HEVC keeps its guard: there is no software route for it, and
  interlaced HEVC is not something a library holds. Pinned by
  `interlacedH264IsRoutedToTheSoftwareDecoderAndProgressiveIsNot`. The opt-in
  `interlacedH264FixtureDecodesInSoftwareWithoutCombing` opens
  `LAGOON_INTERLACED_H264_FIXTURE_URL` and checks every decoded frame for
  row-alternation — a woven field pair on motion scores above 1.5 on that
  metric, deinterlaced output below 1 — with
  `LAGOON_PROGRESSIVE_H264_FIXTURE_URL` as the control that must stay on the
  compressed path.
- **10-bit AV1 and VP9.** Progressive AV1 Main and VP9 profiles 0/2
  direct-play at up to 10-bit. AV1 routing is capability-aware: VideoToolbox
  receives compressed AV1 plus its `av1C` configuration on hardware that
  reports an AV1 decoder, and keeps the full-resolution profile; otherwise the
  pinned dav1d decoder is used, bounded at 3840×2160. That bound was 1920×1080
  until the threading fix, and the HD figure had assumed a single core — 30 s
  of 4K HDR10+ AV1 decodes in 1.66 s threaded, against 13.26 s on one. 8K
  stays out, unmeasured. VP9 always takes the software path and keeps its
  1080p cap; widen a software ceiling only after the frame-loss and memory
  benches show enough CPU and jetsam headroom on hardware. FFmpeg's 8-bit
  planar/NV12 output becomes Core Video NV12. Little-endian planar 10-bit is
  shifted from low-bit words to P010's high-bit layout, with U/V interleaved
  by an ARM NEON primitive (scalar fallback), and native P010 is copied
  stride-aware. Colour primaries, transfer function, YCbCr matrix, range,
  chroma location, pixel aspect and exact presentation timing propagate on
  both paths, as does HDR10 static metadata: the compressed path writes
  mastering display, content light level and `amve` into the format
  description, while the software path attaches the same three payloads to the
  pixel buffer, where `CMVideoFormatDescriptionCreateForImageBuffer` copies
  them into the description so the renderer sees them on every frame. Transfer
  function alone switches tvOS into HDR; without the rest, the display
  tone-maps from its own defaults instead of the master's — which matters here
  because VP9 always takes the software path, and AV1 takes it on every Apple
  TV shipping today.
- **Anamorphic and non-square pixels.** `SampleBufferFactory` attaches
  `kCMFormatDescriptionExtension_PixelAspectRatio` from the stream's
  `sample_aspect_ratio`, and `SoftwareVideoDecoder` attaches the matching
  `kCVImageBufferPixelAspectRatioKey` to its Core Video buffers — the
  prototype the format description is built from, and every frame.
  `videoDimensions()` returns
  `CMVideoFormatDescriptionGetPresentationDimensions` rather than coded
  dimensions, because `videoSize` positions the subtitle overlay, so an
  anamorphic stream would otherwise lay cues out against the wrong box. **The
  1% tolerance is the load-bearing part.** `pixelAspectRatio` returns nil for
  square, for unknown (libavformat's 0/1), and for anything within 1% of
  square, so those format descriptions stay byte-identical. This code is on
  the path every h264/hevc title takes, and the same description goes to
  `AVDisplayCriteria` and `VTDecompressionSessionCreate`. Real files are full
  of rounding artifacts: of 245 items a test library reported as anamorphic,
  203 have a genuine pixel aspect — 16:15 and 64:45 PAL, 4:3
  HDV, 45:44, 8:9 — and 42 are artifacts (1744:1745, 180224:180219, hundredths
  of a percent), so honouring those would have changed 42 descriptions to
  correct nothing visible. Every genuine case there is h264 or mpeg4, and all
  27 hevc items are artifacts, so no VideoToolbox-decoded stream in that
  library carries a PAR extension; whether VideoToolbox propagates the
  attachment onto its output buffers is untested, and would only matter for a
  genuinely anamorphic HEVC source. The device profile no longer excludes
  `IsAnamorphic`, interlaced MPEG-2, or interlaced H.264 routed to the
  software path; interlaced HEVC still transcodes, because the deinterlacing
  stage lives on the software path and HEVC has no route there.

## Subtitles

- **Subtitles.** Rendered as a SwiftUI overlay, never through the renderers.
  Embedded streams decode via `avcodec_decode_subtitle2`, which normalizes
  srt/ass/ssa/mov_text to ASS event payloads — text is everything past the 8th
  comma — and PGS/VobSub to paletted rects converted to CGImages, positioned
  on the codec's graphics plane. External streams, delivered as vtt,
  download and parse into the same cue store. Every subtitle stream is listed
  even if undecodable, so per-type ordinals stay aligned with the server's
  stream list; external tracks append after embedded ones, and the controller
  maps `DefaultSubtitleStreamIndex` into that combined space. Selecting an
  embedded track re-demuxes from the current position — the audio-switching
  trick — so the active line appears immediately; PGS cues are open-ended and
  close on the next composition event. Server Forced/SDH/language metadata is
  merged into embedded and sidecar tracks alike, exposed to Now Playing, and
  retained when a downloaded subtitle is inserted into the running engine. Not
  covered: an embedded subtitle rendition inside an HLS master — remote
  downloads arrive as external files and do work.
- **Cue lifetime.** `SubtitleStore` is a window, not an archive, for embedded
  tracks. The demux loop appends cues as it reads ahead, and the 10 Hz display
  refresh removes every cue whose end has passed the playhead, so an expired
  PGS/VobSub cue releases its RGBA `CGImage` during uninterrupted playback
  instead of at the next seek; each lookup scans only the read-ahead window.
  Eviction keys off the playback position handed to `active(at:)`, never the
  demux cursor, so read-ahead cannot remove a still-visible cue. Open-ended
  PGS cues stay until a later composition or clear closes them, and a clear
  decoded ahead of the clock closes at its own timestamp. A seek or an
  embedded track change resets the window, and the demuxer refills it. A
  downloaded external track keeps its complete cue list behind a forward
  cursor that rebuilds only when time moves backward, so backward seeks need
  no second download. Before this, the store kept every decoded cue until a
  seek: a 91-minute text-subtitle soak stayed flat, but a bitmap track would
  have held a film's worth of images.
- **Subtitle download safety.** External sidecars and files a host fetched from a provider
  share an 8 MiB response cap. The `BoundedDownload` URLSession delegate
  validates HTTP status and checks each delivered chunk, including
  decompressed bytes, before appending, so declared HTML/JSON responses,
  incomplete transfers and files without readable, finite cues cannot replace
  a working track. Selecting an external track keeps the current selection and
  captions until parsing succeeds; a failed replacement exposes a
  track-specific error and Retry in Subtitles, plus a notice over the video
  when the panel is closed. Off, or another selection, cancels superseded
  work; request generations prevent late results from taking over, and
  embedded subtitle writes and replacement commits share the engine lock. None
  of these failures pause or restart playback.
- **ASS/SSA authored placement.** `ASSSubtitleTextParser` keeps each decoded
  text composition separate rather than joining simultaneous speakers into one
  bottom-centre block. It reads `PlayResX/Y` from FFmpeg's subtitle header,
  normalizes `\pos(x,y)` onto the presentation rect, uses `\an1…9` as the
  authored anchor, and retains inline primary colour, bold and italic runs.
  Every other override command is deliberately ignored: this is the useful
  signs/dialogue subset, not a libass replacement. A cue with none of the
  supported overrides takes the exact old `PlayerSubtitleText` path, so
  ordinary SRT/WebVTT and plain ASS dialogue keep the viewer's caption font,
  edge, background and vertical position unchanged.

- **Text encoding.** `SubtitleTextDecoder` replaces a fallback chain that
  ended in `isoLatin1`, which cannot fail — it maps every byte — so a
  Windows-1251 file used to decode to mojibake and render as garbage with no
  error anywhere. A host that converts to UTF-8 on the way out hides this,
  but a subtitle the host fetched directly from its provider arrives as the
  provider stored it, so the decoder still matters.
  Order is BOM, then strict UTF-8, then the codepage implied by the track's
  language (Cyrillic → 1251, Baltic → 1257, and so on), then Windows-1252.
  **Known limitation:** with no language hint, a legacy file still decodes to
  mojibake — Cyrillic bytes read as Latin-1 become ordinary accented Latin
  letters — and separating that from real Western-European text needs
  statistical models; a cheap heuristic would mis-decode German as Cyrillic,
  which is worse. Every path that fetches a subtitle therefore carries a
  language.
