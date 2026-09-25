# Decode

How video gets decoded, and how to measure it. The contract is in the
[engine guide](../engine.md).

## The engine

libavformat demuxes. `AVSampleBufferDisplayLayer` and
`AVSampleBufferAudioRenderer` present under one
`AVSampleBufferRenderSynchronizer`. Per track:

| Content | Path |
| --- | --- |
| H.264, and audio CoreAudio takes | Stays compressed |
| HEVC, and AV1 where the hardware has a decoder | Decoded ahead by a hardware-only VideoToolbox session |
| Other AV1, VP9, VC-1, MPEG-4 Part 2, MPEG-2 | libavcodec on its own decode queue, into renderer-recommended NV12/P010 Core Video buffers |
| 10-bit software output | One asynchronous Metal pass that repacks and, on tvOS, tone-maps (`MetalFrameConverter`) |
| Other compressed audio | libavcodec to LPCM |

AVFoundation still owns colour management, presentation, sync and audio
output.

### Software decode runs off the demux queue

`SoftwareVideoDecodeStage` runs libavcodec on its own queue, shaped like
`VideoToolboxDecoder`. The demux loop submits a packet and moves on; frames and
errors come back through handlers. The demuxer still builds the decoder,
because it has the codec parameters, and hands it over at open
(`takeSoftwareVideoDecoder()`). It never decodes video itself: decoding inline
made reading and decoding take turns, and 4K AV1 is expensive enough for that
to be the bottleneck.

- **Packets are detached, not copied.** `av_packet_clone` shares FFmpeg's
  reference-counted buffer, so a 4K access unit crosses threads for an atomic
  increment.
- **Backpressure counts both halves.** `DemuxBackpressurePolicy` gets
  `videoQueue.count + stage.pendingCount`. Counting only decoded frames lets
  the loop read a whole decoder backlog ahead. `SampleBufferQueue.waitUntilBelow`
  takes an `alsoCounting` closure for the same reason, and the stage calls
  `signalWaiters()` when a packet leaves it.
- **Priming waits for frames, not packets.** `primeAndStart` waits on
  `stage.waitUntilPendingBelow`, or playback starts on an empty renderer.
- **Seeks call `stage.reset()`**, which bumps a generation, empties the
  mailbox and flushes libavcodec synchronously, so the demux loop can reset
  the render queues without racing a frame in flight.
- **EOF calls `stage.finish()`.** Frame threading always leaves pictures inside
  libavcodec, and they are the end of the film. `FFmpegDemuxer` never flushes
  or drains the software decoder: that would touch libavcodec from two queues.
- **Stage frames skip `acceptDecodedVideo`.** That gate drops frames while a
  seek is pending, which is right for VideoToolbox and wrong here. The stage
  already discards pre-seek work on reset, and `videoQueue.reset()` clears the
  rest. Dropping there starves the renderer during stall re-priming (itself a
  seek every couple of seconds), which keeps the stall going: 4 frames shown
  against 2133 on the same title and position.

#### Where the time goes

The HUD's `SWdec:` line and the bench's `swdecode=` field split the cost,
cumulative since the last seek (where the frame-loss bench also re-arms):

```
SWdec:   38.4 ms/frame · budget 92% · 21.7 fps now (23.9 avg) · conv 0.8 ms · read 0% · pending 3
```

**Read `ms/frame` and `budget`, not the rate.** Once the queues fill,
backpressure holds any decoder at the content's frame rate. `budget` is the
cost as a share of one frame period (41.7 ms at 23.976 fps); at or above 100%
the decoder cannot hold frame rate, however healthy the queues look.

- `fps now`: a two-second rolling window. `avg` is cumulative since the seek,
  so a fast priming start stays in it for minutes.
- `decode`: libavcodec. Threaded, so on dav1d it is the wait, not the work.
- `convert`: everything from a decoded AVFrame to a ready `CMSampleBuffer`.
- `read`: `av_read_frame`, as a share of one core.

AV1 decodes to `YUV420P10LE` and the renderer wants P010, so each frame is
shifted to high bits and its chroma interleaved: about 25 MB read and 25 MB
written per 4K frame, 2.5–2.8 ms/frame on the device. The
`VTPixelTransferSession` pass that follows on the transfer route is about
9.6 ms at p50 and can exceed 30 ms at p99. The two are reported separately.

#### Lagoon builds dav1d itself, because upstream's had no assembly

`Artifacts/Libdav1d.xcframework` is built here, with its arm64 assembly, by
`scripts/build-dav1d.sh`. The script verifies the result and fails rather than
emit a C-path binary. **Never remove that check.** A dav1d without assembly
decodes everything correctly, about ten times slower, and nothing fails.
Re-check the committed artifact at any time:

```sh
scripts/build-dav1d.sh --verify-only Artifacts/Libdav1d.xcframework
```

Why: the previous artifact (`mpvkit/libdav1d-build`) was built with

```
"-Denable_asm=false",   // disable "No platform load command found" warning after xcode 15
```

and had 0 NEON symbols, against 2016 in ours. On the
Apple TV it decoded 4K HDR10+ AV1 at 11.4 fps (88 ms/frame), with decode
96–98% of the frame cost. Upstream disabled assembly to silence a real
warning: meson assembles the `.S` files with the C compiler, and without
`-target` the objects carry no platform load command. The script passes
`-target arm64-apple-tvos26.0`, which fixes the warning and keeps the SIMD.

- **Version.** dav1d 1.5.4. To bump: `scripts/build-dav1d.sh --version <tag>`,
  rebuild, then check the API version, exported symbols and headers.
  libavcodec is compiled against a particular dav1d and is not rebuilt with it.
- **No second assembly win.** The archive exports 573 NEON routines, 247 of
  them high-bit-depth. The DotProd and I8MM motion-compensation variants are
  8-bit only, and FFmpeg's wrapper already avoids copying packets and
  pictures, so a direct-dav1d rewrite would mostly replace glue.
- **Vendored, not hosted.** A URL that must outlive the library is a worse
  dependency than eight megabytes in the repository.
- **arm64 carries assembly; x86_64 deliberately does not.** Simulator and
  macOS slices must be fat, because a `generic/platform=tvOS Simulator` build
  links both architectures. x86 assembly comes from nasm, which cannot emit a
  platform load command, and would print 46 warnings on every clean simulator
  link for code that never runs on a device.
- **The framework Info.plists declare `MinimumOSVersion` 100.0.** Do not
  "correct" it. Xcode builds a stub dylib per SwiftPM binary target with that
  value, and App Store validation rejects an app whose minimum equals the
  framework's (`ITMS-90208: … does not support the minimum OS Version
  specified in the Info.plist`). The value has no runtime meaning: dav1d is a
  static archive and the stub never loads. Every artifact declares the same.
  The real deployment targets apply through `-target`.

#### What was tried and retired

Measured on the Apple TV and removed from the code:

| Lever | Result |
| --- | --- |
| Thread count | Keep 5: 13.71% dropped, against 16.71% at dav1d auto, 14.41% at six, 17.55% at eight. Swept at `max_frame_delay=0`, so it says nothing about five against six once depth matches the count |
| Decode queue at `userInteractive` | Never the constraint |
| Film grain synthesis | The test stream carries none |
| Apple's AV1 decoder | Does not exist on an A15 (-12906, even without the hardware requirement) |
| Playback HUD off | Still lags |
| Decoded-frame queue | Empty (`V 0`) with 1.2 GB free, so never memory |
| Conversion on its own CPU queue | Worse, twice (22.2 to 21.2 fps): contention for saturated cores. The GPU stage below pipelines the same work and wins. Parallelising CPU conversion across rows was kept (4.8 to 4.3 ms) |
| Direct renderer P010 instead of the transfer | Worse; see below |

Route AV1 on whether a session can be made, not on
`VTIsHardwareDecodeSupported`, which reports silicon only. AV1 is always
offered to VideoToolbox, and `VideoToolboxDecoder.canDecode` settles it per
stream by creating a session. If that fails, the engine reopens on the software
path. This also covers Apple's warning that a hardware decoder "may not be
available at all times".

#### Measuring on the device itself

Pair the Apple TV, build, install, and launch the host app with whatever
arguments reach playback:

```sh
xcrun devicectl device process launch --device <udid> --console --terminate-existing \
  <bundle-id> -- -debug.decodeTrace YES
```

- The `--` matters: without it devicectl parses `-debug.x` as bundled short
  flags.
- `-debug.decodeTrace YES` prints a `DecodeTrace` line every two seconds:
  position, queue depths (`video=current/peak/hard`, `intake=current/peak` for
  compressed video parked past the decoded limit), the renderer-side audio
  signal (`lead`, `ready`, `aDry`, `audioStalls`, `reprimes`, `buffering`),
  footprint and the decode profile.
- Build from a `git archive` of the commit when others are editing the tree.
  Use `generic/platform=tvOS` as the destination (a rebooting device is not a
  valid `id:`). Run the console under `nohup` so it outlives tool timeouts.

Three rules:

- **Measure Release without coverage.** Debug compiles `LagoonPixelOps` at
  `-O0`: conversion read 28 ms/frame against Release's 4.8 ms. Xcode also
  enables coverage in Release unless told not to, so a benchmarking host
  disables `ENABLE_CODE_COVERAGE` and the coverage linker arguments, and the
  `LagoonPixelOps` target cancels those flags again because Xcode 26 still
  injects them into packages.
- **Compare at a fixed playback position.** Decode cost follows the scene:
  14 ms/frame at the title, 40 ms at 40 s.
- **Use `convertMs` to spot a contaminated run.** No decoder setting affects
  it, so when it drifts from 4.8 ms the device is degrading under load (six
  back-to-back runs pushed it to 9.1 ms). Leave five minutes between runs and
  discard any run not near 4.8. Thermal state and stage tails are sampled over
  fixed 0–10, 20–30, 40–50 and 60–70 s bands; a single `.serious` reading
  proves nothing on its own.

#### Long-film soak lane

For backlogs that grow over an hour, which a 60-second bench cannot see. The
lane forces a subtitle track, then pauses, resumes and exits at set points in
an unattended run and prints how long each call took. With `debug.decodeTrace`
on, `DecodeTrace` adds `mainLateMs` (how late the trace's 2 s sleep resumed,
which tracks main-actor availability), `pumpMs` (a ping through the pump
queue), the cost and cadence of the 10 Hz `observeTime`, the subtitle store
size, the renderer notification-token count and thermal state. `SoakWait`
lines time the pause rate change, `pumpQueue.sync` and renderer retirement.

Baseline, 91 minutes, Apple TV 4K (3rd generation), Release, Dolby Vision
profile 5 with English CC: nothing grew. Footprint flat at 541 MB, zero stalls,
dry-ups and reprimes; `mainLateMs` p99 99 ms, tick ≤ 1.8 ms, pump ping
≤ 2.2 ms; at 90 minutes pause took 72 ms, resume 40 ms, `beginStop()` 122 ms.
Its steady 0.66% drops (`opt=0`) are Dolby Vision on the composited path (next
section).

#### Where the composited-path drops come from

Frame-loss bench, same scene at 600 s, three interleaved runs per arm, Release:

- **The engine is not the bottleneck.** Zero stalls, zero audio dry-ups, and
  the decoded queue never below 29 of 30.
- **HDR never reaches the renderer's optimized display path on this device.**
  A 1080p H.264 SDR title reaches it on 1457–1463 of 1465 frames; every HDR
  arm reports zero.
- **On that composited path, the drops are the subtitle text layer.** Six
  drops in about 1440 frames with a cue on screen, zero with subtitles off or
  a bare surface. HDR10 without Dolby Vision: 0.14–0.21%. Each cue view is now
  a drawing group, rendered once per change; `debug.benchFlatCues` keeps the
  flat path for an A/B (5 · 3 · 3 drops against 9 · 4, about 40% fewer). What
  is left does not line up with cue arrivals.

Both isolation hooks are needed: `debug.benchSubtitleLanguage off`, because the
system caption preference otherwise turns a track on by itself, and
`debug.benchBareSurface`, which removes everything above the video.

#### The display path, measured with a paired device

On the hard scene (35–75 s of the 4K HDR10+ AV1 episode), our dav1d and
libavcodec match Homebrew's on a Mac (177–182 fps). On the Apple TV a bare
decode loop does **55.7 fps**, 39.7 with P010 conversion and a 25-frame queue,
while the host app managed **~20–22 fps** before the CPU fixes below: the gap
was contention, not the decoder.

The renderer's `optimized` counter means Apple's power-efficient mode that
skips UI composition, not "fast frames"
([`AVVideoPerformanceMetrics`](https://developer.apple.com/documentation/avfoundation/avvideoperformancemetrics)).
With the HUD off, hardware HEVC reached it on 87% of SDR frames and 0% of Dolby
Vision. Software output reached 0% on every linear PQ variant and 88%
lossless-compressed and tagged 709.

#### Direct renderer P010 versus the transfer path

Enqueueing the final P010 buffer directly, skipping `VTPixelTransferSession`,
is **worse**: 20.34% dropped against 13.77% for lossless-compressed SDR (six
interleaved runs, Release). It saves 9.8 ms of transfer (2.82 against
12.62 ms/frame), but the libavcodec wait rises 7.8 ms (40.51 against 32.69) and
the starting footprint 359 MB (1305 against 946 MB), with the decoder starved
while the renderer was ready. Direct P010 stays a diagnostic control. A default
transfer configuration the device refuses falls back to linear output; an
explicitly requested matrix mode fails at open rather than silently benchmark
a different path.

- **Check launch-flag parsing before trusting an A/B.** `UserDefaults` stores
  `-key NO` as a string-like value, and `as? Bool` on it silently left the
  transfer enabled.
- AV1 requests `libdav1d` by name, so a future FFmpeg package without it fails
  closed. `maxFrameDelay` is the requested dav1d option; diagnostics also
  report `AVCodecContext.delay`, the effective depth.

#### Where the CPU went, and the two fixes (resolved)

`-debug.decodeTrace YES` also prints a `CPUTrace` line: per-core busy
percentages (`host_processor_info`), process CPU time, and CPU time by thread
name with scheduling priority (`thread_info(THREAD_EXTENDED_INFO)`, in
`DecodeThreadDiagnostics.swift`). The decode queue names its thread. One tick
of the hard scene before the fixes:

```
CPUTrace dt=2.02s coresBusy%=98/99/98/100/100 procMs=7331
  dav1d-worker=6125ms(x5 pri31/31) unnamed=990ms(x8 pri37/37)
  videodecode-q=133ms(x1 pri37/37) main=79ms(x1 pri47/47)
```

The Apple TV 4K (3rd generation) has five cores (two performance, three
efficiency), all saturated. dav1d got 3.0 cores. Half a core went to the pump
queue at a higher priority, and 1.2 cores to other processes.

**Fix 1: arm a renderer request only while there is something to give.**
`requestMediaDataWhenReady` keeps calling its block for as long as the block
enqueues nothing. Registered once and never stopped, both pumps spun whenever
their queue was empty (audio almost always), and the remote renderer burned
cores answering. A pump that finds its queue empty calls
`stopRequestingMediaData()`; `kickPumps()` re-arms it when a buffer arrives
(`armVideoRequests` / `armAudioRequests` / `rearmRequestsIfNeeded`). This
applies to every title. Do not reintroduce a diagnostic that reads thread
dispatch-queue labels: the one that found this retained a dying queue.

**Fix 2: take 12.5 ms of serial conversion off the decode queue.**
`MetalFrameConverter` replaces the CPU repack and the transfer with one compute
kernel (`SoftwareFrameConversion.metal`):

- dav1d's planar 10-bit frame is wrapped in a no-copy `MTLBuffer`. FFmpeg's
  pooled 4K allocations are page-aligned on Darwin; the simulator's driver
  traps on that, so the simulator copies instead.
- The kernel repacks to P010 and, for PQ BT.2020 sources, tone-maps to BT.709
  SDR with the BT.2390 EETF at 203 nits reference white. It writes straight
  into an IOSurface the renderer takes.
- **The dispatch is asynchronous on purpose.** The decode queue returns to
  libavcodec at once, and the dav1d picture stays referenced until the kernel
  has read it.
- `GPUDeliverySequencer` restores submission order, because Metal promises
  nothing about the order of completion callbacks. At most three frames are
  in flight. `flush()` and `drain()` wait for the GPU, so seeks and end of
  stream behave as before.
- Modes: `gpu-sdr` (tvOS HDR default) and `gpu-pq` (default elsewhere for
  10-bit). The transfer modes remain as fallbacks and diagnostics. A stream
  the kernel cannot serve (8-bit, HLG, non-2020) falls back to its transfer
  equivalent at open.

The GPU stage wins where a second CPU queue lost because it costs far less
CPU. Not none: each frame still builds a command buffer and encoder, makes two
texture-cache calls, flushes the cache and runs a completion handler, plus a
staging copy on the simulator.

Same scene, window and device:

| Configuration | Runs | Dropped | Stalls | Min video queue | Frame cost | Cores busy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Before | 3 | 24.8% | 2 | 0 | 43.6 ms | 97-100% |
| + dav1d workers at `.userInitiated` | **1** | 21.5% | 2 | 0 | 42.1 ms | 99-100% |
| + GPU stage, synchronous | **1** | 25.6% | 2 | 0 | 43.3 ms | 97-100% |
| + pump fix and asynchronous GPU stage | **1** | **0.2%** | **0** | **29** | **1.4 ms** | **48-65%** |

> **Not yet replicated.** Only the first row has three runs. The last row's
> effect is far too large to be noise, so the fix stays, but treat its figures
> as one sample each, and do not read the middle rows as a ranking.

The last row is 3 dropped frames in 1463, with the decoder backpressured for
the whole window (`producerStarved=0%`, `downstreamBackpressure=100%`) and
dav1d using 2.05 cores. Thermal state was nominal in every run.

Also learned:

- **The kernel takes 8.7 ms of GPU time on the A15** (0.1–0.35 ms on a Mac),
  p99 near 40 ms under CPU load. Synchronous, it was no better than the
  transfer; asynchronous, it vanishes from the frame cost. Its `pow`-heavy PQ
  and gamma math could move to lookup textures if GPU power ever matters.
- **Raising dav1d's workers to `.userInitiated`** (`-debug.dav1dWorkerQoS`,
  via `pthread_override_qos_class_start_np` on `dav1d-worker` threads) only
  moves time around a saturated CPU: wait fell from 31 to 25 ms, conversion
  rose from 12.6 to 16.7 ms. It stays a diagnostic.
- **Lossless-compressed P010 fails as a Metal destination** at the first
  dispatch on tvOS 26 / A15, though texture creation passes. So `gpu-sdr`
  writes linear P010, and `-debug.softwareDecodeGPULossless YES` proves a
  lossless request with one real conversion before accepting it. Linear costs
  memory: a footprint near 1.67 GB with about 430 MB headroom, which the
  30-frame byte budget was sized for.
- `-debug.softwareDecodeTargetNits` (default 203) sets the tone map's SDR
  white. The source peak comes from mastering metadata, MaxCLL, or 1000 nits.

Regression coverage:

- `GPUDeliverySequencerTests`: ordering, the in-flight cap, the bounded drain,
  failed submissions.
- `MetalFrameConverterTests`, on the simulator GPU: the repack is exact; the
  tone map matches a Double reference within two codes, keeps black black,
  reaches white at the source peak, never inverts a ramp and keeps grey
  neutral.
- The regression probe reports `videoPath` (the live output stage) and
  `idleRequests` (request-block runs with nothing to give).
  `testControlledFrameLossPlaybackPerformance` bounds `idleRequests` in the
  simulator.
- `testSoftwareDecodedPlaybackSurvivesPauseSeeksAndSubtitles` drives a
  software-decoded fixture through pause, seeks both ways and a subtitle
  switch. It asserts that the GPU stage is live, playback continues, the
  request blocks stay quiet and teardown is clean. Run it on a paired Apple
  TV, in Release, against a title the hardware decoder cannot take:

```sh
xcodebuild test -destination 'platform=tvOS,id=<udid>' \
  -only-testing:<UI-test-target>/testSoftwareDecodedPlaybackSurvivesPauseSeeksAndSubtitles
```

It skips in the simulator, whose clock never starts on the fixture's E-AC3
track. Debug stalled seven times on the same seeks where Release stalled none.
Restart the Apple TV first if a previous run was killed mid-playback: a
poisoned media daemon shows up as a media-services reset that leaves the
player paused.

#### Simulator sink ladder

`ApplePlaybackAlignmentTests.av1FixtureReportsDecodeOnlyAndOutputCeilings` is
an opt-in benchmark. Set `LAGOON_AV1_FIXTURE_URL` (and optionally
`LAGOON_AV1_BENCHMARK_FRAMES`) in the test process. It runs two fresh software
decoders, one that discards dav1d frames and one with the full
P010/transfer/sample-buffer output, and reports throughput plus the decode and
conversion breakdown, with no server or renderer.

#### dav1d frame-context depth

dav1d has two limits. `n_threads` sizes one shared worker pool.
`max_frame_delay` caps how many frames that pool advances at once: an explicit
value gives `min(max_frame_delay, n_threads)`, zero gives
`ceil(sqrt(n_threads))`. FFmpeg's wrapper passes both to `dav1d_open`. Sources:
[dav1d's public header](https://github.com/videolan/dav1d/blob/master/include/dav1d/dav1d.h),
[dav1d's scheduler setup](https://code.videolan.org/videolan/dav1d/-/blob/1.5.4/src/lib.c),
[FFmpeg's wrapper](https://ffmpeg.org/doxygen/8.0/libdav1d_8c_source.html).

- Production sets frame delay equal to the explicit worker count before
  `avcodec_open2`: five and five on the Apple TV. `AV_CODEC_FLAG_LOW_DELAY`
  stays off.
- Zero stays available as a launch-argument control for dav1d's square-root
  default. The override is clamped to the useful depth, and experiment values
  are read only from process arguments, so a value persisted by an older
  build cannot reconfigure production.
- Depth five against three, five workers throughout, is worth 34–55%: 43% on
  the dav1d 1.5.4 CLI (about 34% with film grain), 47.7% decode-only and 54.9%
  with full P010 output in a Release simulator (38.2% and 40.0% with grain).
  The simulator figures are one run each, and none of it is device proof.
- The cost: at least two more 3840x2176 YUV420P10 pictures (about 47.8 MiB)
  and up to two frame periods (about 83 ms) of startup or seek latency.

Two smaller changes:

- On the transfer path, the CPU-written P010 buffer is unlocked before
  `VTPixelTransferSessionTransferImage`, and the source AVFrame is released
  right after the copy. That returns a roughly 24 MiB dav1d picture earlier and
  keeps a Core Video CPU lock out of the accelerator.
- Fusing the CPU repack's luma and chroma work into one `concurrentPerform`
  cut p50 by 5–6%. The conversion-chunk count was left alone: one, two and
  three spanned 2.2%, one run each, which is not evidence.
