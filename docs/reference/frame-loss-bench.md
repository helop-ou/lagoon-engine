# Frame-loss bench

Measuring frame loss needs media playing on a screen, so the warmup-and-measure
protocol and its harness live with the host application. This note holds what
the engine owns: the decoded-frame memory ceilings, the arithmetic behind them,
and the leak that set them. Measurement rules are in the [notes
index](README.md#measurement).

## Decoded-frame memory ceiling

The bench samples physical footprint at about 1 Hz over the measured window.
`BenchResult` and its signpost report `memoryStartMB`, `memoryPeakMB`,
`memoryGrowthMB` and the minimum jetsam headroom, `minimumAvailableMB`. Record
it on a physical Apple TV, with a 3840×2160 Main 10 HDR title and any
on-screen overlay off (an overlay changes the video path). The console line
carries the dimensions and whether VideoToolbox or libavcodec decoded, so a
result identifies itself.

**Above about 24 MB a frame, the limit is bytes, not frames.**
`DemuxBackpressurePolicy.videoHardLimit` switches to
`decodedQueueByteBudget`, set to what the hardware path already allowed:
30 frames of 4K P010, 746 MB. The software path's 42-frame limit meant 250 MB
at 1080p 10-bit but 1.05 GB at 4K, in a process jetsam has killed at 2100 MB.
Configurations measured before the byte budget keep their frame limits; only
4K software decode is pulled under it. A floor of 8 frames remains however
large a frame is, because the queue must hold the codec's reorder depth plus
a cushion.

The arithmetic: a 4:2:0 P010 surface is `3840 × 2160 × 3 = 24,883,200` bytes
(23.73 MiB): luma plus half as many chroma samples, in 16-bit words. At the
decoded-video soft and hard limits of 18 and 30 frames, the visible queue is
about 427 and 712 MiB at 4K Main 10. That is an estimate, not a process
ceiling: VideoToolbox may keep 6–16 reorder surfaces and the renderer has its
own, so the bench peak is the authority.

- **Do not lower the 18-frame soft cushion from arithmetic alone.** It is what
  removed steady 4K presentation loss.
- If a device peak leaves too little headroom, reduce the 30-frame hard limit
  first and repeat the identical window.

The renderer feed is kept cheap under high-bitrate load:

- Packet wakeups coalesce onto a user-interactive serial pump.
- The sample FIFO is head-indexed and amortized O(1), not an array shifted per
  frame.
- The demuxer blocks on condition-driven high-water marks and resumes at lower
  thresholds, with no polling.
- Compressed payloads keep FFmpeg's backing buffer (`av_buffer_ref` behind a
  `CMBlockBufferCustomBlockSource`) instead of a per-packet copy.
- Decoded LPCM coalesces into a reused `NSMutableData` that swresample fills
  in place, and then **is copied** into a CoreMedia-owned block at emit.

**Do not make the LPCM emit zero-copy.** Handing that `NSMutableData` to
CoreMedia behind a custom block source leaked the whole decoded audio stream:
the free callback never ran. On TrueHD 7.1 that was about 2.2 MB/s, until
jetsam killed the process at 2100 MB (`per-process-limit`, a `JetsamEvent`
report rather than a crash). The copy costs 1.5 MB/s on the demux queue, about
0.03% of a core. Matched 6.5-minute 4K TrueHD runs: 2 dropped frames of about
9300 and 0 stalls either way; footprint 131 → 113 MB with the copy, 225 →
1003 MB without. The compressed video handoff uses the same block-source
pattern and is leak-free; only the LPCM use regressed.

To tell whether a playback leak is audio or video, play one file twice and
switch only the audio track (TrueHD against AC-3). That holds the video path
constant.
