# Stream recovery

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [engine guide](../engine.md) and the
[notes index](README.md).

## Stream recovery

The engine does not negotiate delivery. A host decides what to request and
how to react to a failure; what follows here is what the engine itself does
when a stream it already opened turns out to be broken in one of four
specific ways, and how it reports the ones it cannot fix on its own.

Every fault the engine cannot recover from is handed back as a
`PlaybackEngineFailure`, whose `cause` is either `.undecodable` — the samples
themselves cannot be decoded here, whether that is a codec outside the
envelope, a decoder session the hardware declined, or a decode that failed,
and only a re-encode changes what the decoder is given — or `.delivery` — the
container, the transport, or an AVFoundation object failed, and the same
media may well play when it arrives another way. The engine does not know
what a host can do about either one; the verdict is the whole of what it
hands over, and what happens next belongs to the host.

### When the container describes no bitstream

Matroska and MP4 are supposed to carry HEVC's VPS/SPS/PPS in the
`CodecPrivate`/`hvcC` record, and `SampleBufferFactory.videoFormatDescription`
builds the format description from it. hev1-style muxing is legal and does not:
it leaves `numOfArrays = 0` and repeats the parameter sets in-band instead.
Found on a 4K WEBDL whose entire `hvcC` was 23 bytes of header.

Nothing complains at the time. `CMVideoFormatDescriptionCreate` builds a
description around the empty record and returns `noErr`; the refusal arrives
later, from `VTDecompressionSessionCreate`, as -4 — while the same file's
in-band parameter sets yield a working 3840x2160 session. So it reads as a
hardware fault and is a container one, which is how it was first misread, and
every other tool disagrees for the same reason: ffprobe, Jellyfin's probe and
libavcodec all parse parameter sets in-band. The file looks healthy everywhere
except the one place the client trusts the container.

`FFmpegDemuxer` therefore checks the record before building anything
(`SampleBufferFactory.hevcExtradataCarriesParameterSets`) and, when it
describes nothing, harvests VPS/SPS/PPS from the opening NALs of the first
video packet and builds through
`CMVideoFormatDescriptionCreateFromHEVCParameterSets`. Notes worth keeping:

- **The header stays valid even with no arrays behind it**, so
  `lengthSizeMinusOne` still describes the packets correctly and the harvest
  can walk them. Parameter sets normally precede the IDR slices in the first
  packet, so the read-ahead ends there; it is bounded at 64 packets regardless.
- **The context is rewound afterwards.** `open()` runs before the demux loop,
  which still owes the renderers every packet from the beginning. A failed
  rewind costs the opening packets and is deliberately not fatal: that is worth
  less than the decoder the harvest buys.
- **Dolby Vision atoms are not attached on this path.** A container that failed
  to describe its own bitstream has not earned trust in its DoVi signalling
  either, and the base layer still presents as HDR10 off the colour tags, which
  is already the documented ceiling for the dual-layer profiles.
- A remux does **not** repair such a file: `ffmpeg -c copy` carries the empty
  record straight over. Rebuilding it needs the video pushed through annex-B.
- **The same refusal has a second cause**, from the opposite direction: a
  container whose record is not a configuration record at all. See *Disc
  images* below, where MPEG-TS hands over Annex-B in the field an `hvcC`
  arrives in.

### A seek that lands in an open GOP

An H.264 High 1080p mkv direct-played for minutes and then reported
`.undecodable` on the first **seek** — a scrub, an embedded subtitle switch
(which re-seeks to the same position), or simply opening the title at a
resume point.

`avformat_seek_file` lands on a Matroska block flagged `AV_PKT_FLAG_KEY`
carrying its own SPS and PPS, a recovery-point SEI, and slices of NAL type
**1**, a coded slice of a *non-IDR* picture. That is an **open GOP**, and the
flag means only that the muxer is willing to seek there. Nothing is missing and
that picture decodes; what fails is one of the two *leading pictures* that
follow the seek point in decode order and are presented before it. They
reference the GOP the renderer's `flush()` has just destroyed. libavcodec
tolerates that and lets a few frames come out wrong; VideoToolbox does not, and
`AVSampleBufferVideoRenderer` answers with `didFailToDecodeNotification`
(-11800 / -12350), which is `.undecodable`: on its own terms serious enough
that a host's only recourse would be re-encoding the whole film, over two
frames nobody was ever going to see.

So the demuxer drops them. `VideoRandomAccessPoint` (pure, unit-tested)
classifies the first video packet after every seek: an IDR for H.264, the IRAP
range 16–21 for HEVC. When it *is* one — closed-GOP content, which is nearly
everything — nothing changes. When it is a keyframe that is not one, the
following packets presented before it are dropped until decode order passes it,
bounded at 32 packets. Everything dropped sits before the point the seek landed
on, at or before the position the viewer asked for, so none of it was ever
going to be shown; on the file above that is two packets per seek
(`SeekLeadingPictures dropped=2` under `-debug.decodeTrace YES`).

The engine also got tolerant of this shape of failure, because the next
container to invent one should cost a hiccup rather than force a host into
re-encoding the whole film. `PlaybackRestartPointPolicy`: a decode failure
within the first three video samples after a flush earns **one** in-place
recovery — flush, re-seek to the same position through the ordinary seek path
— before `.undecodable` is reported. The retry is recorded against the
playback generation the re-seek starts, so a second failure at the same
position reports `.undecodable` exactly as before, one seek later, and a
later seek earns its own retry. It cannot loop.

Worth knowing when this comes back: only the compressed path reaches
`AVSampleBufferVideoRenderer`, so a software-decoded stream never showed this,
and neither does HLS, whose fMP4 segments start on IDRs — a delivery method
built around segment boundaries never exhibits this failure at all. It is
decoder-dependent too: the A15 played the same seek clean before the fix and
only the simulator refused the leading pictures, so the drop is what keeps
the simulator lane honest on open-GOP encodes.

### A decode session the system took back

Three field reports, on both an Apple TV and an iPhone, surfaced a
VideoToolbox status that was never about the bitstream. `-12903` is
`kVTInvalidSessionErr`: the decode *session* is gone and needs remaking.
`failVideoDecode` flattened every decoder error to `.undecodable`, on the
reasonable-sounding assumption that redelivering the same bitstream cannot
help — true of a frame the decoder refused, false of a session that no
longer exists.

The renderer path had been hardened for exactly this twice, and the decoder
path neither time. `recoverVideoRendererIfRequired` and
`handleVideoRendererFailure` both bail while `videoOutputSuspended`;
`failVideoDecode` had no such check. The in-place retry above had exactly
one caller, the renderer failure path, so direct-play HEVC and AV1 — which run
through `VideoToolboxDecoder` and never reach a renderer failure — had no retry
at all and were terminal on the first fault. `VideoToolboxDecoder.reset()`
already recreated a session and was called only from the seek branch, never
from an error path.

The two reported shapes need different halves of the fix:

- `LAGOON-G`, an iPhone, `appState: background`, DoVi direct play, 39 s in.
  Background playback deliberately leaves the VT session alive, because
  making a new one in the background can be refused. But
  `setVideoOutputSuspended(true)` only sets a flag on the main actor: the demux
  loop applies the discard at the top of its *next* iteration, and
  `deliverVideo`/`admitVideo`/`drainVideoIntake` gate only on `cancelled`, so a
  sample in flight can still reach a session iOS has already torn down. The
  fallback then tried to reload a film into the foreground of an app that was
  not in the foreground — `outcome: cancelled`, as it had to be. **This race is
  reasoned from the code, not reproduced.** The misclassification it exposes is
  plain from the funnel regardless of how the session was lost.
- `LAGOON-A`, an Apple TV, `appState: **active**`, `sinceSeekMs: 178`,
  reported as `sessionCreation`. Not the background race at all: the seek
  branch's own `videoDecoder?.reset()` failed to build a session, on a stream
  that had been playing.

So `VideoToolboxDecoder.isSessionFault` names the three statuses that mean the
decoder was taken away rather than the samples refused: `kVTInvalidSessionErr`,
`kVTVideoDecoderMalfunctionErr`, `kVTVideoDecoderNotAvailableNowErr`.
`PlaybackDecodeSessionPolicy` decides what to do, bounded exactly as
`PlaybackRestartPointPolicy` is and for the same reason: one rebuild per
playback generation, recorded against the generation the re-seek starts. A
session that genuinely cannot be made is reported as `.undecodable` one seek
later and cannot loop. Suspended video ignores the fault outright — there is
nothing to rebuild for, and the resume seek makes a fresh session anyway.

**A rebuild is a seek, and a seek needs a demux loop still running to apply
it.** That is the whole trap in this fix, and it is worth stating before the
call sites, because absorbing a fault on a path that is about to stop the loop
does not save the playback — it replaces a reported failure with a spinner
that never resolves and never errors, which is strictly worse than reporting
the failure and letting a host fall back, however wasteful that fallback is.
So absorption is opt-out, `allowSessionRecovery: false`, wherever the caller
is about to stop the loop or has never started one:

- **Decoder construction at open** (before the loop is entered, and it
  `return`s instead of entering it). A decoder the system will not hand out at
  open is reported outright — that is exactly what `.undecodable` exists to
  say, because redelivering the same bitstream cannot help.
- **The seek branch**, where returning false `break`s the loop. It retries
  `reset()` in place instead and only reports `.undecodable` if the second
  attempt fails too.
- **Cancelled playback**, via the policy's `tooLate`: the samples draining out
  of a decoder being torn down all report the session going with it.

`finishVideoInput` is the one absorbing path that keeps going: at EOF a dead
session costs the last frames it was holding, and both reporting a failure
and seeking to rebuild would be worse than losing them, so it records and
falls through to the finish boundary.

`alreadyRecovering` is deliberately not recorded. A decoder can hold dozens of
samples and each reports the same dead session on its way out; a breadcrumb
apiece would evict the history that explains the incident. The rebuild they are
all waiting on is recorded, on the main actor, once it is known which of the
two outcomes it was. The near-the-end branch that declines to seek spends the
generation's rebuild anyway. Otherwise every remaining sample would ask for
another one.

Both outcomes report on the renderer-recovery channel they mirror, as
`recovery: decodeSessionRebuilt` and `decodeSessionIgnored`; only the rebuild
is reported as an incident, because the ignored ones are expected and would be
noise. The `rendererRecoveries` counter is built from engine counters, not from
these events, so the degradation thresholds are unaffected.

Still owed: a hardware run. Nothing here has been seen to recover on a device —
the classification is verified by unit tests and the builds are green, but
"a rebuilt session actually resumes playback on an Apple TV" is a device check,
and the background race above wants a reproduction before anyone trusts the
account of it. `LAGOON-B` (`-12909`, bad data, one access unit mid-film) is a
different mechanism — per-frame tolerance with a budget — and is deliberately
left alone here.

### Disc images

A disc image — a Blu-ray or DVD ISO — is a filesystem, not a stream, and
needs a title picked out of it before the engine can treat it as one.
`UDFVolume` resolves a name to its extents and `DiscStreamMap` presents a
title's extents to the demuxer as one linear stream, through the byte-range
AVIO the playback cache already provides; mounting a Blu-ray costs about 15
range requests and under a megabyte. Because the reader lives behind the
cache session, a disc keeps its session even once the image is completely
cached: an ordinary complete file plays straight from disk without one, but a
disc handed to libavformat as a plain file is the raw image again, which
libavformat cannot open — a fact `PlaybackBufferPolicy.engineUsesCacheSession`
exists to prevent. Four things about that were not obvious:

- **UDF 2.50 hides every file entry inside a metadata partition** — a file in
  the physical partition that the volume then addresses as a partition of its
  own — while the data those entries describe stays outside it. A reader that
  resolves every allocation descriptor in the entry's own partition finds empty
  directories, which is exactly what the first draft did.
- **A DVD image needs no second filesystem.** It is UDF 1.02, the same reader
  minus the metadata partition, and it mounted an authored image unchanged. No
  ISO9660 reader was written.
- **The longest playlist is usually a menu loop.** WALL·E's `00020.mpls` plays
  two clips 303 times and reports 323 minutes, more film than the image
  physically holds; counting each clip once collapses it to 2 minutes. Four
  real candidates then sit between 98.2 and 98.7 minutes, and the only thing
  separating them is a runtime hint the host supplies (`runtimeSeconds`): a
  server-probed 98.11 picks the right one, and without the hint the longest
  collapsed title wins. Ties break by name so the choice cannot wobble between
  mounts.
- **A title is not one file.** Seamless branching splits WALL·E's into 42 clips
  and the filesystem fragments some of those again, 71 extents in all. A DVD
  title is its largest title set's VOBs in numeric order, part 0 excluded
  because that is the menu.

The concatenated title's duration agrees with the host's runtime hint to
within a third of a second, so the presentation timeline stays continuous
across every clip boundary.

#### What MPEG-TS breaks that no probe reports

ffprobe, Jellyfin and libavcodec handle both of the following without comment;
only Apple's decoder and Lagoon's own timeline cared.

**MPEG-TS is Annex-B; every other container Lagoon plays is length-prefixed.** A
correctly mounted disc failed at `VTDecompressionSessionCreate` with "could not
create a hardware decoder". libavformat synthesises `extradata` for MPEG-TS out
of the in-band parameter sets and hands it over still in Annex-B; read as an
`hvcC` it describes a stream that does not exist, and the samples carry start
codes as well, which VideoToolbox cannot decode whatever the description says.
Confirmed against Apple's decoder with the disc's own record: read as an `hvcC`
the session is refused with -4, built from the parameter sets read out of it it
is created at 3840x2160. `AnnexBStream` reads those parameter sets out of a
start-code record and rewrites every payload with four-byte lengths, for H.264
as well as HEVC; the enhancement-layer filter runs after that conversion so it
and VideoToolbox see one framing. This is the same failure reached from the
other side: a description that builds successfully and a decoder that refuses it.

**A container's clock is not the film's clock.** The same disc then played but
opened reading 1:10:00 with a scrubber that would not move. MPEG-TS starts at
whatever timestamp the muxer chose, and this disc's streams begin at
4198.333333 s (377850000 at 90 kHz). Every packet carried that origin into the
renderers, and every seek asked for a timestamp 70 minutes before the first
frame, which the demuxer clamped to the start. `ContainerTimeline` now removes
the format's origin from packets as they are read and adds it back onto seeks.
Measured origins, which is why this had never come up:

| path | origin |
| --- | --- |
| MKV direct play | 0 |
| Jellyfin HLS transcode | -0.042667 s (encoder delay, negative, ignored) |
| Jellyfin HLS remux | +0.005 s |
| DVD image | +0.54 s |
| Blu-ray image | +4198.33 s |

Taking the *format's* origin rather than each stream's own is deliberate: this
disc starts its video and first audio track together and a second audio track
two thirds of a second later, and that offset is content, not clock.

Neither disc path covers Dolby Vision profile 7: `DolbyVisionProfileConverter`
keys off a DoVi configuration record that MPEG-TS images do not carry, so
such a disc plays as HDR10 from the base layer. H.264 Blu-rays
(everything before 4K) and real DVD images are unexercised — the DVD path was
built against an image authored with `dvdauthor` for the purpose, for want of
a real one to test against.
