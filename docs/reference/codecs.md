# Codec, timing and subtitle details

Per-codec behaviour, timestamp handling and subtitles. The generated
[codec support table](../codec-support.md) says what decodes; this says how.

## Codec and timing details

### Compressed packets stay zero-copy

- Matroska stores h264 and hevc the way CoreMedia wants, so a packet becomes a
  sample buffer with no repacking.
- CoreAudio takes aac, mp3, ac3 and eac3 compressed. ac3 and eac3 describe
  themselves; aac needs its AudioSpecificConfig as the magic cookie.
- Packet cadence prefers FFmpeg's parsed `frame_size` and falls back by codec,
  including 576 samples for MPEG-2/2.5 Layer III at 24 kHz and below.
- The CoreMedia block holds the packet's `AVBufferRef` (`av_buffer_ref`) and
  releases it after decode: no clone, no second allocation, no payload copy.
- pts, dts and duration convert to `CMTime` in the stream's exact rational
  time base, never through floating point or a fixed 90 kHz scale.

### Audio decode

Audio CoreAudio will not take compressed (DTS, TrueHD, FLAC, Opus, Vorbis,
anything else FFmpeg decodes) goes through `AudioDecoder`: libavcodec, then
swresample, then interleaved Float32 LPCM, coalesced to about 2048-sample
chunks because TrueHD frames are only 40 samples. swresample writes into a
reused allocation, and each chunk is then **copied** into a CoreMedia-owned
block at emit. Do not remove that copy: skipping it leaked the whole decoded
audio stream (see [the decoded-frame memory
ceiling](frame-loss-bench.md#decoded-frame-memory-ceiling)).

FFmpeg's native channel order matches CoreAudio's channel bitmap on the first
18 positions, so a native layout mask maps straight into the
`AudioChannelLayout`.

The renderer's format is fixed at open from the stream's declared rate and
layout, and every resampler resamples to that. A stream can change shape
mid-way: a TV recording that joins a stereo advert to a 5.1 programme, or a
44.1 kHz stretch in 48 kHz, which ADTS AAC in MPEG-TS carries per frame. So
`AudioDecoder` rebuilds its resampler whenever the input's sample format,
rate or channel layout changes, and sizes each conversion from
`swr_get_out_samples`, since upsampling needs more room than came in. It
used to rebuild only for a new sample format: a resampler kept for six planes
read past a stereo frame's two and crashed, and a 44.1 kHz stretch played at
48 kHz, fast and sharp.

AAC with no codec configuration is decoded here too, not passed through
(`AudioDecodePolicy`). That is ADTS, as MPEG-TS carries it: a seven-byte
header on every frame and no AudioSpecificConfig for the magic cookie.
CoreAudio never played it, and the clock waited on the audio: on the Apple
TV 4K (3rd gen) a TS recording with AAC stalled a second in, buffering, with
no error, while the same audio in MKV and AC-3 in TS played. Decoded here it
plays, and it follows the stereo and 5.1 changes broadcast streams make,
which a passthrough format fixed at open cannot. A TS clip whose AAC went
stereo, 5.1, then stereo at 44.1 kHz stalled at 0.97 s on 1.0.11 and played
all nine seconds after.

`AudioDecoderResampleTests` feeds synthetic frames that change shape; its
opt-in test reads `LAGOON_LAYOUT_CHANGE_TS_FIXTURE_URL`. The fixture is three
two-second MPEG-TS clips joined with `cat`: `sine` encoded with `-c:a aac -f
mpegts` as stereo 48 kHz, 5.1 48 kHz (`pan=5.1|c0=c0|…`) and stereo 44.1 kHz.

### Atmos from E-AC3 JOC

Verified on hardware. When FFmpeg reports `AV_PROFILE_EAC3_DDP_ATMOS`, the
format description needs:

- the **`'ec+3'` media subtype** (Apple's "Enhanced AC-3 with JOC", no public
  constant);
- **`mChannelsPerFrame = 16`**, the HLS `CHANNELS="16/JOC"` presentation;
- the synthesized `dec3` box (ETSI TS 102 366 Annex F) as magic cookie and
  extension atom.

Plain `ec-3` passthrough does not work, nor does
`kAudioChannelLayoutTag_Atmos_9_1_6` alone or with `ec-3` and `dec3`: both
decode only the DD+ core and report "Multichannel".

### Timestamps

- **LPCM.** Each buffer is stamped at the sample-exact end of the previous
  one, at the stream's own sample rate, re-anchoring to container pts only on
  jumps over 50 ms. Matroska stamps to 1 ms but TrueHD frames are 0.83 ms, and
  90 kHz cannot represent 48 kHz boundaries. Either mismatch is steady
  clicking.
- **Passthrough audio.** An AAC frame is 1024 samples, 21.33 ms, which
  Matroska's 1 ms stamps cannot hold, so pts jitters up to about 1.7 ms and
  each jump crackles. (EAC3's 1536 samples are exactly 32 ms, so it was
  immune.) `PassthroughAudioTimeline` chains pts sample-exactly from one
  anchor and re-anchors only on forward gaps over **half a packet**, so one
  missing packet cannot become a permanent A/V offset (a 50 ms tolerance would
  hide it). Backward packets past that tolerance overlap queued audio and are
  dropped until the container catches up; this absorbs the HLS AAC boundary
  sequence (four 1-sample packets, then a short preroll packet). Seeks reset
  the chain. The HUD's `aGaps` must read 0 during untouched playback.
- **Video frame grid.** Matroska quantizes video pts to 1 ms; a 23.976 fps
  frame is 41.708 ms. `VideoFrameTimeline` snaps each pts to the nearest whole
  frame step from the previous snapped stamp, in signed steps (decode order
  walks backwards through B-frames), in exact integer arithmetic in the frame
  rate's timescale. Stamps more than 5 ms off (VFR, broken mux) pass through
  and re-anchor. Decode stamps stay the container's. This is scheduling
  accuracy, **not** a frame-loss fix: hardware A/Bs dropped at the same rate
  either way, so do not blame frame loss on timestamp jitter. The HUD's
  `Vtime: grid N/D` line is the check.
- **A rate rounded to the millisecond.** Some mkvmerge files declare 23.976
  fps as a 42 ms default duration, which FFmpeg reports as 500/21 (23.81).
  Trusting it kept the display at 60 Hz and pushed the grid out of tolerance
  every ~17 frames: judder with zero dropped frames. The demuxer corrects it
  to the standard rate when the `NUMBER_OF_FRAMES`/`DURATION` statistics
  agree. A `grid 500/21` or `1000/33` in the HUD means a file without them.

### HEVC decode-ahead and presentation order

Handing compressed full-raster 4K Main10 straight to the renderer drops
frames. `VideoToolboxDecoder` decodes HEVC ahead, in the engine, and wraps the
IOSurface-backed pixel buffers as ready sample buffers.

- The pool reconciles tvOS 26's `recommendedPixelBufferAttributes` with the
  engine's IOSurface and Metal needs. Pixel format stays unconstrained, so
  VideoToolbox keeps native bit depth and colour attachments. Ambient viewing
  environment metadata is restored on output as a fallback.
- Decoder callbacks are not in presentation order. A bounded PTS queue holds
  at least six frames, or FFmpeg's reported codec delay capped at 16, and emits
  strict display order.
- Seek recreates the decoder and discards the old callback generation. EOF
  finishes delayed frames before waiting.
- A seek-preroll `kVTVideoDecoderReferenceMissingErr` is scoped to that access
  unit: drop the frame, let the session recover at the next reference picture,
  never abort.
- The decoded queue's **18-frame high / 12-frame low watermark** is a
  0.50–0.75 s cushion at 23.976 fps. On the Apple TV 4K (3rd generation) it
  took the original 4K HDR10 failure from about 10% loss to **0 / 1462**, with
  zero stalls and audio gaps. On Snowden's 610 s stress scene the earlier 12/8
  lost 1.25–1.65% with 3–11 stalls and `minQ=0`; 18/12 gave **0 / 1438** with
  `minQ=10`. Measure with the HUD off: the same build dropped 5 / 1445 with the
  overlay up. See the [bench procedure](frame-loss-bench.md#frame-loss-bench).
- No sub-second cushion survives a feed below real time (sustained 91 Mbps
  pulls slowed even probing to 20–40 s). Those cases correctly buffer.

### VC-1

tvOS has no VC-1 VideoToolbox decoder, but the renderer accepts ready Core
Video image buffers.

- The engine keeps the original MKV and audio, decodes progressive 8-bit VC-1
  with libavcodec, copies planar 4:2:0 into renderer-recommended NV12
  IOSurface/Metal buffers, carries colorimetry and exact timing, and wraps
  each image with `CMSampleBufferCreateReadyWithImageBuffer`.
- The advertised profile is capped at 1080p progressive; anything else takes a
  server transcode.
- With VC-1, AC-3 is decoded locally to LPCM. That keeps the file in one
  original stream and avoids the HLS fragment boundary that caused repeating
  audio cut-outs. E-AC-3/Atmos, and AC-3 beside other video, stay
  passthrough.
- Chroma interleaving is an ARM NEON C primitive with a scalar fallback.
  Software VC-1 holds a 30/24-frame decoded reserve with a 42-frame hard
  ceiling.
- Each packet iteration has its own autorelease pool. The demux worker is one
  long-lived dispatch item, so its outer pool would hold Core Media scratch
  allocations until dismissal.

### MPEG-4 Part 2

Xvid/DivX AVI uses the same libavcodec → Core Video path:
`SoftwareVideoDecoder.supports`, an `avi` container and a bounded `mpeg4`
profile. Simple and Advanced Simple Profile are 8-bit 4:2:0 by specification,
exactly what the software decoder takes. AC-3 beside it decodes locally
through `AudioDecodePolicy.requiresLocalPCM`, which keys on
`softwareVideoDecoded`, not on VC-1.

**Packed bitstream.** Old rips pack two VOPs into one AVI chunk, followed by a
7-byte "VOP not coded" packet. libavcodec logs `Discarding excessive bitstream
in packed xvid` and handles it, with exact frame accounting. A sweep of 197
AVI titles found 29 packed, 1 damaged (the server transcode fails on it too)
and no zero-size packets. That matters: a zero-size packet is libavcodec's
drain signal and would end the stream. The `mpeg4_unpack_bframes` BSF is in
the build if a defect appears; the demuxer has no bitstream-filter plumbing
yet.

### MPEG-2, PCM and DVB subtitles

- Progressive SDR MPEG-2 uses the 8-bit 4:2:0 software path up to 1080p;
  interlaced MPEG-2 plays too.
- MPEG program stream, transport stream and VOB containers are included, for
  DVD and recorded TV.
- PCM variants, Blu-ray LPCM and DVD LPCM use the libavcodec → Float32 LPCM
  path.
- DVB bitmap subtitles use the paletted-rectangle decoder and overlay that PGS
  and VobSub use.

### Deinterlacing

The software path makes an interlaced frame progressive before copying it
out. It is written here, not linked: yadif lives in libavfilter, which is not
among the artifacts, and adding it is a dependency decision.

- `Deinterlacer` does yadif's spatial half: predict along the direction the
  image runs, and keep the original sample wherever the two fields agree. That
  agreement test stands in for the temporal half, so a still shot keeps full
  vertical resolution and only motion is interpolated.
- Against yadif on a real interlaced frame: 0.34 levels per pixel of 255, at
  1.61 ms per frame at 720x576.
- The frame is made writable first: it may still be a reference for later
  pictures.
- Only codecs with a software route lose their `IsInterlaced` guard (MPEG-2,
  and H.264 below). Without that, a server answers an interlaced DVD image
  with a transcode and the image never reaches the engine.

### Interlaced H.264

A device profile cannot say "interlaced only", so the demuxer splits it:
`FFmpegDemuxer.isInterlaced(fieldOrder:)` reads the probed field order.

- Interlaced H.264 goes to `SoftwareVideoDecoder` and the deinterlacer.
  `supports` accepts H.264 only on that route, so a failed hardware
  description for progressive H.264 still fails instead of decoding on the
  CPU.
- Progressive H.264 stays compressed on VideoToolbox. Unknown field order
  counts as progressive.
- HEVC keeps its guard: it has no software route, and interlaced HEVC is rare
  in libraries.
- Tests: `interlacedAndTenBitH264AreRoutedToSoftwareAndPlainH264IsNot`. The
  opt-in `interlacedH264FixtureDecodesInSoftwareWithoutCombing` opens
  `LAGOON_INTERLACED_H264_FIXTURE_URL` and scores every frame for row
  alternation (a woven field pair on motion scores above 1.5, deinterlaced
  output below 1), with `LAGOON_PROGRESSIVE_H264_FIXTURE_URL` as the control
  that must stay compressed.

### 10-bit H.264

No Apple hardware decoder takes H.264 High 10 (Hi10P, common in older anime
releases), so VideoToolbox refuses it and the demuxer sends it to software
too. `FFmpegDemuxer.isHighBitDepthH264` reads what the probe parsed from the
SPS: a 10-bit pixel format, else a sample depth above 8, else the High 10
profile. A stream whose container or server metadata names no profile is
still caught. Anything unknown counts as 8-bit and stays on hardware.

- The output is P010, as for 10-bit AV1 and VP9. Interlaced 10-bit H.264 is
  decoded but not deinterlaced; the deinterlacer is 8-bit only.
- Tests: `tenBitH264IsReadFromTheStreamNotItsLabel`, and the opt-in
  `hi10PH264FixtureProducesReadyP010Frames`, which opens
  `LAGOON_HI10P_H264_FIXTURE_URL`. A fixture:
  `ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=24 -t 6 -c:v libx264
  -pix_fmt yuv420p10le -profile:v high10 hi10p.mkv`.

### 10-bit AV1 and VP9

- Progressive AV1 Main and VP9 profiles 0/2 play at up to 10-bit.
- AV1 goes to VideoToolbox, with its `av1C` configuration, where the hardware
  reports a decoder, at full resolution. Otherwise dav1d, bounded at
  3840×2160: threaded, 30 s of 4K HDR10+ AV1 decodes in 1.66 s, against
  13.26 s on one core. 8K is out, unmeasured.
- VP9 always takes the software path, capped at 1080p. Widen a software
  ceiling only after the frame-loss and memory benches show CPU and jetsam
  headroom on hardware.
- 8-bit planar/NV12 output becomes Core Video NV12. Little-endian planar
  10-bit is shifted to P010's high bits, with U/V interleaved by an ARM NEON
  primitive (scalar fallback). Native P010 is copied stride-aware.
- Colour primaries, transfer, matrix, range, chroma location, pixel aspect and
  exact timing propagate on both paths, and so does HDR10 static metadata. The
  compressed path writes mastering display, content light level and `amve`
  into the format description. The software path attaches the same payloads
  to the pixel buffer, and `CMVideoFormatDescriptionCreateForImageBuffer`
  copies them into the description. The transfer function alone switches tvOS
  into HDR; without the rest, the display tone-maps from its own defaults
  instead of the master's.

### A stream that changes size

Broadcast MPEG-2 and H.264 switch between SD and HD at programme boundaries,
and joined files do the same. On the Apple TV 4K (3rd gen), 720p, 1080p, 720p
clips with continuous timestamps behaved like this:

- **H.264 through the compressed renderer and HEVC through VideoToolbox**
  played through; the parameter sets travel in the stream.
- **The software path** (VP9, AV1 without AV1 silicon, MPEG-2, VC-1, MPEG-4,
  interlaced H.264) failed on its first frame, `.undecodable`, whatever the
  pixel format: its pools, pixel-transfer or Metal stage and format
  description were all built for the size read at open.

`SoftwareVideoDecoder` now rebuilds everything sized to the picture when a
frame of a new size arrives (`reconfigureOutput`), in the output mode chosen at
open, so a new size never changes how frames are coloured. GPU frames still in
flight drain first, since they carry the old description. 8-bit VP9, MPEG-2
576 to 1080, and 10-bit VP9 on the GPU path all played through on the device.

`videoSize` follows too: decoded frames publish their presentation size when
it changes, so a host lays subtitles out against the new picture. Progressive
H.264 reaches the renderer compressed, so its size stays the one read at open.
A change of bit depth mid-stream is still a verdict.

The opt-in test `aStreamThatChangesSizeDecodesAtEachSize` reads
`LAGOON_RESOLUTION_CHANGE_FIXTURE_URLS`, comma-separated. Make each fixture
by joining same-codec clips of two sizes with ffmpeg's concat demuxer
(`-f concat -c copy`), not `cat`, which restarts the timestamps.

### Anamorphic and non-square pixels

- `SampleBufferFactory` attaches `kCMFormatDescriptionExtension_PixelAspectRatio`
  from the stream's `sample_aspect_ratio`. `SoftwareVideoDecoder` attaches
  `kCVImageBufferPixelAspectRatioKey` to the prototype buffer and every frame.
- `videoDimensions()` returns
  `CMVideoFormatDescriptionGetPresentationDimensions`, not coded dimensions,
  because `videoSize` positions the subtitle overlay.
- **The 1% tolerance is load-bearing.** `pixelAspectRatio` returns nil for
  square, for unknown (libavformat's 0/1) and for anything within 1% of
  square, so those descriptions stay byte-identical. This is on every h264 and
  hevc title's path, and the same description goes to `AVDisplayCriteria` and
  `VTDecompressionSessionCreate`. Of 245 items a test library called
  anamorphic, 203 were genuine (16:15 and 64:45 PAL, 4:3 HDV, 45:44, 8:9) and
  42 were rounding artifacts (1744:1745, 180224:180219).
- Every genuine case there was h264 or mpeg4; all 27 hevc items were
  artifacts. Whether VideoToolbox carries the attachment onto its output is
  untested, and matters only for genuine anamorphic HEVC.
- A host's device profile need not exclude `IsAnamorphic`, interlaced MPEG-2
  or interlaced H.264. Interlaced HEVC still needs a transcode.

## Subtitles

- **Decoding.** Subtitles render as an overlay, never through the renderers.
  Embedded streams decode through `avcodec_decode_subtitle2`, which turns
  srt/ass/ssa/mov_text into ASS event payloads (the text is everything after
  the 8th comma) and PGS/VobSub into paletted rects, converted to CGImages on
  the codec's graphics plane. External vtt, srt and ASS/SSA files download
  and parse into the same cue store; an ASS script's `Dialogue` lines go
  through the same subset parser as embedded events (`SubtitleParser.scriptCues`),
  and the script itself goes to libass.
- **Track list.** Every subtitle stream is listed, even if undecodable, so
  per-type ordinals match the server's stream list. External tracks follow
  embedded ones, and the host maps `DefaultSubtitleStreamIndex` into that
  combined space. Server Forced/SDH/language metadata is merged into embedded
  and sidecar tracks, exposed to Now Playing, and kept when a downloaded
  subtitle is inserted into a running engine.
- **Selection.** Text streams (SubRip, ASS, WebVTT, mov_text) are demuxed
  even while unselected, and `SubtitleBacklog` keeps each one's recent events
  (120 s behind its newest, at most 4,096). Selecting one replays them into
  `SubtitleStore` and libass, so the line already on screen appears at once,
  with no seek. A seek re-demuxed only from the keyframe before the position,
  missing a line that started earlier, and flushed the video on the main
  actor (57–76 ms per switch on an Apple TV 4K). The backlog restarts on a
  seek. Bitmap streams (PGS, DVD, DVB) are still discarded while unselected
  and still re-demux from the current position when chosen. PGS cues are
  open-ended and close on the next composition. Not covered: an embedded
  subtitle rendition inside an HLS master (downloads arrive as external files
  and work).
- **Cue lifetime.** For embedded tracks `SubtitleStore` is a window, not an
  archive. The demux loop appends cues as it reads ahead, and the 10 Hz
  display refresh removes every cue whose end has passed the playhead, so an
  expired bitmap cue frees its RGBA `CGImage` during playback. Eviction keys
  off the position passed to `active(at:)`, never the demux cursor, so
  read-ahead cannot remove a visible cue. Open-ended PGS cues stay until a
  later composition or clear closes them; a clear decoded ahead of the clock
  closes at its own timestamp. A seek or embedded track change resets the
  window. A downloaded external track keeps its full cue list behind a forward
  cursor that rebuilds only when time moves backward, so backward seeks need
  no second download.
- **Download safety.** External sidecars and files a host fetched from a
  provider share an 8 MiB response cap. The `BoundedDownload` URLSession
  delegate checks HTTP status and each delivered chunk (decompressed bytes
  included) before appending, so HTML/JSON responses, incomplete transfers and
  files without readable, finite cues cannot replace a working track.
  Selecting an external track keeps the current selection and captions until
  parsing succeeds. A failed replacement shows a track-specific error with
  Retry in Subtitles, plus a notice over the video when the panel is closed.
  Off, or another selection, cancels superseded work. Request generations stop
  late results taking over, and embedded subtitle writes and replacement
  commits share the engine lock. None of these failures pause or restart
  playback.
- **Styled ASS/SSA (libass).** An ASS or SSA track, embedded or a sidecar,
  renders through libass in `StyledSubtitleRenderer`: named styles, `\fn`,
  `\fs`, karaoke, `\move`, `\fad`, clips, rotation, borders and `\p`
  drawings, in the fonts the file carries as Matroska attachments, then
  CoreText's. libass draws for a moment rather than per cue, so the renderer
  runs on its own queue at the video frame rate (capped at 30 Hz), reads the
  synchronizer's timebase, and publishes premultiplied images through
  `currentSubtitleImages` only when the picture changes: one per cluster of
  overlapping pieces, so a top karaoke line and the bottom dialogue are two
  small images rather than one covering the frame. The overlay treats them
  as it treats PGS. The bench line's `styledSubs` field gives the render and
  composite cost per changed frame; on the Apple TV 4K (3rd gen), a 1080p24
  opening with two `\kf` karaoke lines, `\blur`, a moving sign and dialogue
  cost 10.1 ms average and 47–58 ms peak, with no frames lost (2026-09-29,
  four runs). Splitting the blend into regions did not lower it (9.4 ms with
  one image), so the time is most likely libass's own rendering; the split
  was not measured. Embedded events reach libass as raw Matroska chunks
  (`SubtitleEvent.styledChunk`) beside the parsed cue; libass drops
  duplicates by ReadOrder, so re-demuxing after a seek is harmless. The parsed
  cues still feed `currentSubtitleText` for Media Accessibility, but not the
  overlay. The canvas is the video size capped at 1920×1080, with the storage
  size set to the video so borders and blur scale with it.
  `EngineTuning.rendersStyledSubtitles` (on by default) turns it off, and a
  renderer that fails to start leaves the track to the cue parser below.
  Tests: `StyledSubtitleRendererTests`; the opt-in
  `theFixturesAttachedFontReachesLibass` opens
  `LAGOON_STYLED_ASS_FIXTURE_URL`, a Matroska file whose styles name a font it
  carries as an attachment
  (`ffmpeg … -c:s ass -attach Font.ttf -metadata:s:t:0 mimetype=application/x-truetype-font`).
- **ASS/SSA placement without libass.** `ASSSubtitleTextParser` keeps each
  text composition separate instead of joining simultaneous speakers into one
  bottom-centre block. It reads `PlayResX/Y` from FFmpeg's subtitle header, maps
  `\pos(x,y)` onto the presentation rect, uses `\an1…9` as the anchor, and
  keeps inline primary colour, bold and italic. Every other override is
  ignored on purpose: this is the fallback subset for when libass is off.
  A cue with none of these overrides takes the plain `PlayerSubtitleText`
  path, so SRT, WebVTT and plain ASS dialogue keep the viewer's caption style
  and position.
- **Text encoding.** `SubtitleTextDecoder` tries the BOM, then strict UTF-8,
  then the codepage implied by the track's language (Cyrillic → 1251, Baltic
  → 1257, and so on), then Windows-1252. Never end the chain in `isoLatin1`:
  it maps every byte, so it never fails, and a Windows-1251 file decodes to
  silent mojibake. A subtitle fetched straight from a provider arrives in
  whatever encoding the provider stored. **Known limitation:** with no
  language hint, a legacy file still decodes to mojibake. Telling that from
  real Western European text needs statistical models, and a cheap heuristic
  would mis-decode German as Cyrillic. So every path that fetches a subtitle
  carries a language.
