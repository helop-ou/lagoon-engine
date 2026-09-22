# Frame-loss bench

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [engine guide](../engine.md) and the
[notes index](README.md).

## Frame-loss bench

Measuring frame loss needs media actually playing on a screen, which the
engine alone cannot arrange, so the warmup-and-measure protocol and the
harness that reads its results live with whichever host application plays
the content, not here. What belongs to the engine is what those
measurements are checked against below: the decoded-frame memory ceilings,
the arithmetic behind them, and the leak postmortem that produced the
current numbers.

### Decoded-frame memory ceiling

The bench samples physical footprint at roughly 1 Hz over the same
warmup-delimited window. `BenchResult` and its signpost report
`memoryStartMB`, `memoryPeakMB`, `memoryGrowthMB` and the minimum jetsam
headroom as `minimumAvailableMB`. Record it on a physical Apple TV for a
3840×2160 Main 10 HDR title with any on-screen diagnostic overlay off, so
the overlay does not alter the video path. The console line carries the
presentation dimensions and whether the stream used VideoToolbox or
libavcodec, which makes a captured result self-identifying.

Above roughly 24 MB a frame, the frame *count* stops bounding anything
useful and `DemuxBackpressurePolicy.videoHardLimit` falls back to bytes.
The software path's 42-frame limit was chosen when it carried SD and HD
video, where 42 frames meant 250 MB at 1080p 10-bit. But software AV1
reaching 4K made those same 42 frames 1.05 GB of P010 surfaces, in a
process jetsam has already killed once at 2100 MB. The budget,
`decodedQueueByteBudget`, is deliberately set to the ceiling the
hardware-decoded path was already permitted (30 frames of 4K P010, 746 MB).
Every configuration measured before this change keeps the limit it was
measured with, and only 4K software decode is brought back under it. A
floor of 8 frames survives however large a frame gets, because a queue
still has to hold the codec's reorder depth plus a cushion.

The arithmetic behind those figures: a 4:2:0 P010 surface is `3840 × 2160
× 3 = 24,883,200` bytes (23.73 MiB), luma plus half as many chroma samples
in 16-bit words. That makes Lagoon's visible queue alone roughly 427/712
MiB at 4K Main 10, with the decoded-video soft/hard limits of 18/30
frames. It is an estimate, not a process ceiling. VideoToolbox may retain
6–16 reorder surfaces and the renderer owns another private set, which is
why the bench peak is the authority. Do not lower the 18-frame soft
cushion from arithmetic alone. It is the reserve that removed steady 4K
presentation loss. If a physical peak leaves too little headroom, reduce
the 30-frame hard limit first and repeat the identical window.

The renderer feed is kept cheap under high-bitrate load. Packet wakeups are
coalesced onto a user-interactive serial pump. The engine-side sample FIFO
is head-indexed and amortized O(1) rather than shifting its whole Swift
array for every frame. The demuxer blocks on condition-driven video/audio
high-water marks and resumes at lower thresholds instead of polling queue
counts. Compressed payloads retain FFmpeg's existing backing buffer
(`av_buffer_ref` behind a `CMBlockBufferCustomBlockSource`) instead of
being copied per packet. Decoded LPCM coalesces into a reused
`NSMutableData` that swresample fills in place, and then **is copied** into
a CoreMedia-owned block at emit. All of this reduces Lagoon's copying,
allocation, scheduling and ARC overhead. Codec decode remains
AVFoundation's.

**Do not make the LPCM emit zero-copy.** An earlier version handed that
`NSMutableData` to CoreMedia behind a custom block source, and
the free callback never ran. Lagoon leaked the entire decoded audio stream
at ~2.2 MB/s on TrueHD 7.1, and jetsam killed it for `per-process-limit` at
2100 MB partway through a movie, with a `JetsamEvent` report rather than a
crash trace. The copy that bought that back costs 1.5 MB/s on the demux
queue, roughly 0.03% of a core, and cannot reach the render path. A matched
pair of 6.5-minute 4K/TrueHD runs measured 2 dropped frames out of ~9300
either way and 0 stalls, with footprint going 131 → 113 MB fixed versus
225 → 1003 MB leaking. The compressed video handoff uses the same
block-source pattern and is measured leak-free, so the pattern itself is
fine. Only the LPCM use of it regressed. It was isolated by playing one
file twice and switching only the audio track (TrueHD vs AC-3), which holds
the video path constant. That is the fastest way to attribute a playback
leak to audio or video.
