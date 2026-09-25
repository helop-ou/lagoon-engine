# Stream recovery

What the engine does when a stream it already opened turns out to be broken,
and how it reports what it cannot fix. It does not negotiate delivery: the
host decides what to request and what to do on failure.

A fault the engine cannot recover from becomes a `PlaybackEngineFailure`:

- `.undecodable`: the samples cannot be decoded here (a codec outside the
  envelope, a session the hardware declined, a failed decode). Only a
  re-encode changes that.
- `.delivery`: the container, the transport or an AVFoundation object failed.
  The same media may play when it arrives another way.

The verdict is all the engine hands over.

### When the container describes no bitstream

Matroska and MP4 should carry HEVC's VPS/SPS/PPS in the `CodecPrivate`/`hvcC`
record. hev1-style muxing is legal and does not: it leaves `numOfArrays = 0`
and repeats the parameter sets in-band. `CMVideoFormatDescriptionCreate`
accepts the empty record with `noErr`, and `VTDecompressionSessionCreate`
later refuses it with -4, so it looks like a hardware fault. Every other tool
(ffprobe, Jellyfin's probe, libavcodec) parses parameter sets in-band and
reports the file as healthy.

So `FFmpegDemuxer` checks the record first
(`SampleBufferFactory.hevcExtradataCarriesParameterSets`). If it describes
nothing, the demuxer harvests VPS/SPS/PPS from the first video packet's
opening NALs and builds through
`CMVideoFormatDescriptionCreateFromHEVCParameterSets`.

- **The header stays valid with no arrays behind it**, so
  `lengthSizeMinusOne` still describes the packets and the harvest can walk
  them. The read-ahead normally ends in the first packet; it is bounded at 64.
- **The context is rewound afterwards**, because the demux loop still owes the
  renderers every packet from the start. A failed rewind loses the opening
  packets and is deliberately not fatal.
- **No Dolby Vision atoms on this path.** A container that cannot describe its
  bitstream is not trusted on DoVi either. The base layer still presents as
  HDR10 from the colour tags.
- A remux does **not** repair such a file: `ffmpeg -c copy` copies the empty
  record. Rebuilding it needs the video pushed through Annex-B.
- The same -4 has a second cause: an MPEG-TS record that is Annex-B, not a
  configuration record. See [What MPEG-TS
  breaks](#what-mpeg-ts-breaks-that-no-probe-reports).

### A seek that lands in an open GOP

Symptom: an H.264 MKV that plays fine reports `.undecodable` on the first
seek (a scrub, an embedded subtitle switch, which re-seeks, or a resume point).

`avformat_seek_file` lands on a block flagged `AV_PKT_FLAG_KEY` whose slices
are NAL type **1**, a non-IDR picture: an **open GOP**. That picture decodes.
The two *leading pictures* after it in decode order, presented before it,
reference the GOP the renderer's `flush()` just destroyed. libavcodec
tolerates that; VideoToolbox does not, and `AVSampleBufferVideoRenderer`
posts `didFailToDecodeNotification` (-11800 / -12350), which is
`.undecodable`.

**The demuxer drops leading pictures after a seek.** `VideoRandomAccessPoint`
(pure, unit-tested) classifies the first video packet after every seek: IDR
for H.264, IRAP (NAL types 16–21) for HEVC. If it is one, nothing changes
(nearly all content). If it is a keyframe that is not, the following packets
presented before it are dropped until decode order passes it, bounded at 32
packets. None of them would have been shown. `-debug.decodeTrace YES` logs
`SeekLeadingPictures dropped=N`.

**One retry after a flush.** `PlaybackRestartPointPolicy`: a decode failure
within the first three video samples after a flush earns one in-place
recovery (flush, re-seek to the same position) before `.undecodable` is
reported. The retry is recorded against the playback generation the re-seek
starts, so a second failure there reports as before and a later seek earns
its own retry. It cannot loop.

Only the compressed path reaches `AVSampleBufferVideoRenderer`, so
software-decoded streams never show this, and HLS fMP4 segments start on IDRs.
It is decoder-dependent too: the A15 played the same seek clean, and only the
simulator refused the leading pictures.

### A decode session the system took back

VideoToolbox `-12903`, `kVTInvalidSessionErr`, means the decode *session* is
gone and needs remaking, not that the samples were refused.

**Rule: a session fault is rebuilt, not reported as undecodable.**
`VideoToolboxDecoder.isSessionFault` names the three statuses that mean the
decoder was taken away: `kVTInvalidSessionErr`, `kVTVideoDecoderMalfunctionErr`,
`kVTVideoDecoderNotAvailableNowErr`. `PlaybackDecodeSessionPolicy` decides,
bounded like `PlaybackRestartPointPolicy`: one rebuild per playback
generation, recorded against the generation the re-seek starts. A session
that actually cannot be made is reported as `.undecodable` one seek later.
While video output is suspended, the fault is ignored: there is nothing to
rebuild for, and the resume seek makes a fresh session anyway.

Two field shapes:

- iPhone in the background, DoVi direct play. Background playback keeps the
  VideoToolbox session alive, because creating one in the background can be
  refused. `setVideoOutputSuspended(true)` only sets a flag, which the demux
  loop applies on its next iteration, and `deliverVideo`/`admitVideo`/
  `drainVideoIntake` gate only on `cancelled`, so a sample in flight can still
  reach a session iOS already tore down. This race is reasoned from the code,
  not reproduced.
- Apple TV, active, 178 ms after a seek: the seek branch's own
  `videoDecoder?.reset()` failed to build a session.

**A rebuild is a seek, and a seek needs a running demux loop.** Absorbing a
fault on a path that is about to stop the loop turns a reported failure into
a spinner that never resolves, which is worse. So absorption is opted out with
`allowSessionRecovery: false` wherever the loop is stopping or never started:

- **Decoder construction at open**, before the loop runs. A decoder the system
  will not hand out at open is `.undecodable`.
- **The seek branch**, where returning false breaks the loop. It retries
  `reset()` in place and reports `.undecodable` only if that fails too.
- **Cancelled playback**, through the policy's `tooLate`: samples draining out
  of a decoder being torn down all report the session going with it.

`finishVideoInput` absorbs and keeps going: at EOF a dead session costs the
last few frames, which is better than failing or seeking. It records and falls
through to the finish boundary.

Reporting:

- `alreadyRecovering` is not recorded. A decoder holding dozens of samples
  reports the same dead session for each, and a breadcrumb apiece would evict
  the history that explains the incident. The rebuild is recorded once, on the
  main actor, with its outcome.
- The near-the-end branch that declines to seek still spends the generation's
  rebuild, or every remaining sample would ask for another.
- Outcomes go out on the renderer-recovery channel as `recovery:
  decodeSessionRebuilt` and `decodeSessionIgnored`. Only a rebuild is an
  incident. The `rendererRecoveries` counter comes from engine counters, not
  these events, so degradation thresholds are unaffected.

Still owed: a device run showing a rebuilt session actually resumes, and a
reproduction of the background race. `-12909` (bad data in one access unit
mid-film) is a different mechanism, per-frame tolerance with a budget, and is
not handled here.

### Disc images

A Blu-ray or DVD ISO is a filesystem, not a stream. `UDFVolume` resolves a
name to its extents, and `DiscStreamMap` presents a title's extents to the
demuxer as one linear stream, through the cache's byte-range AVIO. Mounting a
Blu-ray costs about 15 range requests and under a megabyte.

A disc keeps its cache session even once the image is fully cached: handed to
libavformat as a plain file it is the raw image again, which libavformat
cannot open. `PlaybackBufferPolicy.engineUsesCacheSession` enforces that.

- **UDF 2.50 hides every file entry inside a metadata partition** (a file in
  the physical partition, addressed as a partition of its own), while the data
  those entries describe stays outside it. Resolving every allocation
  descriptor in the entry's own partition finds empty directories.
- **A DVD image is UDF 1.02**: the same reader without the metadata partition.
  No ISO9660 reader is needed.
- **The longest playlist is usually a menu loop.** One title's `00020.mpls`
  plays two clips 303 times for 323 minutes; counting each clip once collapses
  it to 2. Four real candidates then sit between 98.2 and 98.7 minutes, and
  only the host's runtime hint (`runtimeSeconds`) separates them. Without the
  hint the longest collapsed title wins. Ties break by name, so the choice is
  stable across mounts.
- **A title is not one file.** Seamless branching split one title into 42
  clips, fragmented to 71 extents. A DVD title is its largest title set's VOBs
  in numeric order, excluding part 0 (the menu).

The concatenated title's duration matches the runtime hint to within a third
of a second, so the timeline stays continuous across clip boundaries.

#### What MPEG-TS breaks that no probe reports

**MPEG-TS is Annex-B; every other container is length-prefixed.** libavformat
synthesises MPEG-TS `extradata` from the in-band parameter sets, still in
Annex-B. Read as an `hvcC` it describes a stream that does not exist (session
refused with -4), and the samples carry start codes VideoToolbox cannot decode.
`AnnexBStream` reads the parameter sets out of a start-code record and
rewrites every payload with four-byte lengths, for H.264 and HEVC. The
enhancement-layer filter runs after that conversion, so it and VideoToolbox
see one framing.

**A container's clock is not the film's clock.** MPEG-TS starts at whatever
timestamp the muxer chose; one Blu-ray starts at 4198.333333 s (377850000 at
90 kHz). Carried into the renderers, that made the film open at 1:10:00, and
every seek landed before the first frame and was clamped to the start.
`ContainerTimeline` removes the format's origin from packets as they are read
and adds it back onto seeks. Measured origins:

| Path | Origin |
| --- | --- |
| MKV direct play | 0 |
| Jellyfin HLS transcode | -0.042667 s (encoder delay, negative, ignored) |
| Jellyfin HLS remux | +0.005 s |
| DVD image | +0.54 s |
| Blu-ray image | +4198.33 s |

Use the *format's* origin, not each stream's: streams can legitimately start
at different times (one disc's second audio track starts two thirds of a
second after the video), and that offset is content, not clock.

Not covered: Dolby Vision profile 7 on a disc (`DolbyVisionProfileConverter`
needs a DoVi configuration record, which MPEG-TS lacks, so it plays as HDR10).
H.264 Blu-rays and real DVD images are unexercised; the DVD path was built
against an image authored with `dvdauthor`.
