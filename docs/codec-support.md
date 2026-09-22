# Codec support

What the engine decodes, and by which path. Generated from `EngineCodecSupport`
by `scripts/generate-codec-support.sh` — edit that table, not this file.

A codec reaching VideoToolbox is handed to AVFoundation in its container's
own bitstream form and never touches this engine's decoder. A software codec
is decoded by libavcodec on the CPU.

## Video

| Codec | Path | Notes |
| --- | --- | --- |
| H.264 | VideoToolbox, software fallback | Progressive H.264 is handed to the renderer compressed. Interlaced H.264 decodes in software, because that is the only path with a deinterlacer. |
| HEVC | VideoToolbox | Always compressed, interlaced included. There is no software fallback, and a device without HEVC hardware fails the title rather than decoding it on the CPU. |
| AV1 | VideoToolbox, software fallback | VideoToolbox when the device can make a session for the stream, and libdav1d when it cannot. Which one you get is decided by trying, once, at open. |
| VP9 | Software | Always software. |
| VC-1 | Software | Always software: Apple ships no VideoToolbox decoder for it. |
| WMV3 | Software | Always software: Apple ships no VideoToolbox decoder for it. |
| MPEG-4 Part 2 | Software | Always software. The Xvid and DivX envelope. |
| MPEG-2 | Software | Always software, and deinterlaced when the frames say they are interlaced. |

The software path takes 8-bit and 10-bit 4:2:0 only. Anything else — 4:2:2,
4:4:4, 12-bit — fails the title rather than being converted, because a
silent conversion is worse than an error that says what happened.

## Audio

| Codec | Given to the renderer as | Notes |
| --- | --- | --- |
| AAC | kAudioFormatMPEG4AAC | Passed through with the stream's own AudioSpecificConfig. |
| AC-3 | kAudioFormatAC3 | Passed through, except alongside software-decoded video, where it is decoded to PCM instead: the two together interrupted audio. |
| E-AC-3 | kAudioFormatEnhancedAC3 | Passed through with a synthesized EC3SpecificBox. |
| E-AC-3 with Atmos | 'ec+3' | Joint object coding is passed through whole. Tagging it as ordinary E-AC-3 would have the system decode the core only. |
| MP3 | kAudioFormatMPEGLayer3 | Passed through. |
| Anything else | Linear PCM | Decoded to linear PCM by the linked FFmpeg build, which is what decides the real list — this engine keeps no allow-list. DTS, TrueHD, FLAC, Opus and Vorbis reach the renderer this way. TrueHD is never passed through, Atmos or not. |

## Dynamic range

HDR10 is carried whole: mastering display colour volume, content light level
and the ambient viewing environment all reach the renderer. HLG and the
ordinary BT.709 and BT.2020 transfers are tagged from the container.

Dolby Vision profile 5 is presented as Dolby Vision. Profile 8 keeps its
base layer's tags and adds the Dolby Vision record beside them, so a display
without Dolby Vision still gets HDR10. Profile 7's enhancement layer is
dropped and its RPU converted to profile 8.1 in flight. Profile 4 and any
other profile play as HDR10 off the colour tags.

HDR10+ is not read, and not removed either: its metadata rides inside the
bitstream on the compressed path. Whether a display acts on it is not
something this engine decides, so it is not claimed here.

On tvOS, HDR that decodes in software is tone-mapped to SDR by default.

## Interlacing

Interlaced H.264, MPEG-2, VC-1, WMV3 and MPEG-4 Part 2 are deinterlaced,
8-bit only, by a spatial filter that weaves where the fields agree and
interpolates along the best-matching direction where they do not.

Interlaced HEVC is not deinterlaced. It stays on the compressed path,
whatever its field order says.

