# Decode

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [engine guide](../engine.md) and the
[notes index](README.md).

## The engine

libavformat demux → codec-specific stages →
`AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` under one
`AVSampleBufferRenderSynchronizer`. H.264 and supported audio codecs stay
compressed. HEVC and hardware-supported AV1 are decoded ahead by a
hardware-only VideoToolbox session. AV1 without that capability, along with
VP9, VC-1, MPEG-4 Part 2, and MPEG-2, is software-decoded by libavcodec into
renderer-recommended NV12/P010 Core Video buffers, on a decode queue of its
own (see below). 10-bit output goes through a Metal kernel that repacks and,
on tvOS, tone-maps in one asynchronous pass (`MetalFrameConverter`).
Unsupported compressed audio is decoded to LPCM by libavcodec. AVFoundation
still owns color management, presentation, synchronization, and audio
output.

### Software decode runs off the demux queue

Until 0.1 (73), `FFmpegDemuxer.readNext()` called
`softwareVideoDecoder.decode(packet:)` inline, and `readNext` runs on
the engine's demux queue. Reading and decoding took turns, and both
queues drained while a frame was inside libavcodec. It never mattered
while the software path's customers were SD and HD MPEG-2, VC-1 and
MPEG-4. Every path with real per-frame decode cost went to
VideoToolbox, which is asynchronous. 4K AV1 is the first content
expensive enough for the serialisation itself to be the problem.

The decoder now lives in `SoftwareVideoDecodeStage`, on a queue of its
own, shaped like `VideoToolboxDecoder`. The demux loop submits and
moves on. Frames arrive through an output handler, and failures arrive
through an error handler. The demuxer still *builds* the decoder,
because that is where the codec parameters are, and hands it over
during open (`takeSoftwareVideoDecoder()`). It never decodes video
again. Three things follow from that, and each is load-bearing:

- **Packets are detached, not copied.** `av_packet_clone` shares
  FFmpeg's reference-counted buffer, so handing a 4K access unit to
  another thread is an atomic increment. The demuxer's own packet is
  unref'd on the way out of `readNext` as it always was.
- **Backpressure counts both halves.** `DemuxBackpressurePolicy` is
  given `videoQueue.count + stage.pendingCount`. Decoded frames and
  packets the stage still owes are both video already read and not
  yet shown. Counting only the first lets the loop read an entire
  decoder backlog ahead of itself the moment decode stops happening
  on its queue. `SampleBufferQueue.waitUntilBelow` takes an
  `alsoCounting` closure for the same reason, and the stage calls
  `signalWaiters()` when a packet leaves it.
- **Priming waits for frames, not for packets.** "Read enough" and
  "decoded enough" used to be the same moment and no longer are, so
  `primeAndStart` waits on `stage.waitUntilPendingBelow` rather than
  starting playback on an empty renderer.

Seeks go through `stage.reset()`, which bumps a generation, empties
the mailbox, and flushes libavcodec synchronously, so the demux loop
can reset the render queues behind it without racing a frame still in
flight. EOF goes through `stage.finish()`, because frame threading
always leaves pictures inside libavcodec, and they are the end of the
film. `FFmpegDemuxer` no longer flushes or drains the software decoder
at all. Doing both would touch libavcodec from two queues at once.

**Frames from the stage do not go through `acceptDecodedVideo`.**
That gate drops anything arriving while a seek is merely *pending*,
which is right for VideoToolbox and wrong here. The stage discards its
own pre-seek work when the demux loop resets it, and
`videoQueue.reset()` clears whatever landed in between, so both ends
are already covered. Dropping there starves the renderer exactly while
stall recovery is re-priming, and re-priming *is* a seek every couple
of seconds, so the drop keeps the queue empty, which keeps the stall
going. Caught as 4 displayed frames against 2133 on the same title,
position and stall loop.

#### Where the time goes

The HUD's `SWdec:` line and the bench's `swdecode=` field separate
the costs, cumulative since the last seek, which is also where the
frame-loss bench re-arms, so a bench window and the profile describe
the same stretch:

```
SWdec:   38.4 ms/frame · budget 92% · 21.7 fps now (23.9 avg) · conv 0.8 ms · read 0% · pending 3
```

**Read `ms/frame` and `budget`, not the rate.** Once the queues fill,
backpressure holds the decoder at playback rate, so a decoder with
headroom to spare and one with none both settle at the frame rate of
the content. Cost per frame does not move when the decoder is
throttled, and `budget` expresses it as a fraction of one frame period
(41.7 ms at 23.976 fps), so anything at or above 100% cannot hold
frame rate however healthy the queues look. Two builds during this
investigation were read wrongly before the line said so. `fps now` is
a two-second rolling window. `avg`, being cumulative since the seek,
keeps a fast priming start in it for minutes. `decode` is libavcodec
(threaded, so on dav1d this is the wait, not the work), `convert` is
everything between a decoded AVFrame and a ready `CMSampleBuffer`, and
`read` is `av_read_frame` as a share of one core.

AV1 decodes to `YUV420P10LE` and the renderer wants P010, so every
frame is shifted from low bits to high and its chroma interleaved.
That is roughly 25 MB read and 25 MB written per 4K frame, about
600 MB/s at 24 fps, measured at 2.5–2.8 ms/frame on the device. It
matters, but it is not the dominant cost. The `VTPixelTransferSession`
pass that used to follow it is about 9.6 ms at p50 and can exceed
30 ms at p99. The two are reported separately rather than hidden in
one conversion average.

#### Lagoon builds dav1d itself, because upstream's had no assembly

The pipeline change above was necessary and was not the fix. On an
Apple TV the split read **decode 96-98%, convert 2%, read 0%**, at
11.4 fps against the 23.976 a 4K HDR10+ AV1 episode needs. Conversion
and delivery were never close to being the constraint, which retired
two planned levers, GPU conversion and decoding into IOSurfaces,
without having to try either.

The arithmetic pointed past threading. An earlier measurement found
18.4 ms/frame single-threaded on a 12-performance-core Mac. The device
was taking 88 ms, 4.8x slower than *one* Mac thread, which no
core-count or IPC difference explains. Bounding the count to the
performance cluster made it worse (9.1 fps), so it was not
under-threading either.

It was the binary. `mpvkit/libdav1d-build`, where the artifact came from,
builds dav1d with:

```
"-Denable_asm=false",   // disable "No platform load command found" warning after xcode 15
```

Every AV1 frame Lagoon had ever decoded ran dav1d's portable C path.
mpvkit's libdav1d has 0 NEON symbols, against 2402 in libavcodec from
the same bundle and 2016 in the one `scripts/build-dav1d.sh` produces.
The warning upstream was silencing is real: meson assembles dav1d's
`.S` files with the C compiler, and without an explicit `-target`
those objects carry no platform load command. Passing `-target
arm64-apple-tvos26.0` fixes it properly and keeps the SIMD, which is
what the script does. It also retro-explains that earlier Mac number:
18x real time across twelve performance cores is only 1.5x per core,
which is what a C-path dav1d looks like. Twelve fast cores hid it.
Two cannot.

`Artifacts/Libdav1d.xcframework` is therefore the one artifact Lagoon
builds rather than fetches, vendored rather than hosted because a URL
that has to outlive the library is a worse dependency than eight
megabytes in the repository. It first shipped as dav1d 1.5.3, matching
mpvkit's version exactly so that nothing about the result could be
attributed to a version change rather than to the assembly. It is now
1.5.4, taken only once the assembly change had been measured on its
own. Bumping it is `scripts/build-dav1d.sh --version <tag>` and a
rebuild, after which check the API version, the exported symbols and
the headers, because libavcodec here is a binary compiled against a
particular dav1d and cannot be rebuilt alongside it. Do not go looking
for a second assembly win. The archive exports 573 NEON routines
including 247 high-bit-depth ones, the newer DotProd and I8MM
motion-compensation variants are 8-bit-only, and FFmpeg's wrapper
already references packet storage and dav1d pictures rather than
copying either, so a direct-dav1d rewrite would mostly replace glue.

**arm64 carries assembly. x86_64 deliberately does not.** The
simulator and macOS slices have to be fat, because a
`generic/platform=tvOS Simulator` build compiles both architectures
and will not link against a slice carrying one. x86 assembly comes
from nasm, which cannot emit a platform load command, so keeping it
would print 46 warnings on every clean simulator link for code that
never runs on a device or on Apple silicon at all. That is the same
trade upstream made, defensible only when scoped to an architecture
that never ships.

**The framework Info.plists declare `MinimumOSVersion` 100.0**,
which is not a mistake and must not be "corrected" to the real
deployment target. Xcode builds a stub dylib per SwiftPM binary
target using that value, and App Store validation requires the app's
minimum not to exceed the framework's, so declaring the app's own
minimum sits exactly on that boundary and is rejected (`ITMS-90208:
… does not support the minimum OS Version specified in the
Info.plist`). That is what happened to build 74. The value has no
runtime meaning, because the stub never loads: dav1d is a static
archive linked into the app binary, and every artifact beside it
declares the same thing. The deployment targets still apply
to the code itself, through `-target`.

Re-check the committed artifact at any time:

```sh
scripts/build-dav1d.sh --verify-only Artifacts/Libdav1d.xcframework
```

The build script runs that check itself and fails rather than emit a
C-path binary. **Never remove it.** A dav1d without its assembly
decodes every file correctly and merely slowly, so nothing fails,
nothing looks wrong, and nobody finds out until someone measures 4K
on a device with two performance cores. That is exactly how this
shipped in the first place.

#### What was tried and retired

Everything below was measured on the Apple TV and is gone from the
code rather than left switched off, because a settings page full of
levers that do nothing is worse than no levers. The measurements are
kept so nobody re-derives them.

| lever | result |
| --- | --- |
| Thread count | Keep 5: 13.71% dropped at five against 16.71% at dav1d auto, 14.41% at six, 17.55% at eight; eight lowered the median send call and made its p95/p99 much worse. Swept at `max_frame_delay=0`, so it says nothing about five versus six once the depth matches the count |
| Decode queue at `userInteractive` | never the constraint once heat was |
| Film grain synthesis | **this stream carries none**, reported by the HUD in one playback |
| Apple's AV1 decoder | **does not exist on an A15**: -12906 with the hardware requirement already dropped |
| Playback HUD off | still lags |
| Decoded-frame queue | empty (`V 0`) with 1.2 GB free, so never the memory |
| Conversion on its own CPU queue | *worse*, twice: decode rose by about what conversion stopped adding, 22.2 fps became 21.2. Contention for saturated cores, not proof that no pipelined design works — the GPU stage below pipelines the same work and wins. Parallelising the CPU conversion across rows *was* kept (4.8 to 4.3 ms; only that much because the copy is bounded by memory bandwidth, not cores) |
| Direct renderer P010 instead of the transfer | falsified below; production stays on lossless-compressed SDR |

The AV1 row left something behind. `PlaybackCapabilities` used to
route on `VTIsHardwareDecodeSupported`, which reports silicon and
nothing else, and went straight to libdav1d on a false. It never
asked whether VideoToolbox had a software decoder, which Apple does
ship on some platforms. AV1 is now always offered to VideoToolbox and
`VideoToolboxDecoder.canDecode` settles it per stream by trying to
create a session. Where the answer is no, the engine reopens on the
software path rather than failing the title. That also covers the
hardware case Apple warns about, where a decoder "may not be
available at all times".

#### Measuring on the device itself

An Apple TV can be paired, which changes what is knowable. With
`xcrun devicectl` the loop is build, install, launch the host
application with whatever arguments get it into playback, and read a
console time series:

```sh
xcrun devicectl device process launch --device <udid> --console --terminate-existing \
  <bundle-id> -- -debug.decodeTrace YES
```

The `--` matters: devicectl's parser reads `-debug.x` as bundled
short flags without it. `-debug.decodeTrace YES` prints a
`DecodeTrace` line every two seconds with position, queue depths
(`video=current/peak/hard`, `intake=current/peak` for compressed
video parked past the decoded limit), the renderer-side audio signal
(`lead`, `ready`, `aDry`, `audioStalls`, `reprimes`, `buffering`),
footprint, and the full decode profile. Build from a `git archive` of
the commit rather than the working tree when agents are editing it.
Use `generic/platform=tvOS` as the destination (a rebooting device is
not a valid `id:` destination). Run the console process under
`nohup` so the run outlives any tool timeout.

Three rules came out of doing this badly first:

**Measure Release without coverage.** A Debug build compiles
`LagoonPixelOps` at `-O0`, which reported conversion at 28 ms a frame
against Release's 4.8 ms and made decode look cheap by comparison.
Every conclusion drawn from that was wrong. Xcode also enables LLVM
coverage in Release unless told otherwise, so a benchmarking host's
own app target disables `ENABLE_CODE_COVERAGE` and the coverage
linker arguments there, and the Swift-package `LagoonPixelOps` C
target cancels those flags again because Xcode 26 still injected them
into packages. Those are the only loops that touch every pixel.

**Compare at a fixed playback position.** Decode cost tracks scene
complexity: 14 ms a frame at the title, 40 ms in the scene at 40 s. A
cumulative average read at a different position compares scenes, not
settings, which invalidated an entire thread-count sweep and a
frame-delay A/B.

**Use `convertMs` as the contamination detector.** It cannot depend
on any decoder setting, so when six back-to-back runs pushed it from
4.8 ms to 9.1 ms that was the device degrading under continuous
load, not the settings. Leave five minutes between runs and discard
any run where it is not near 4.8. For the same reason the diagnostic
samples thermal state and stage tails over fixed 0–10, 20–30, 40–50
and 60–70 second bands rather than reporting one end-state.
`.serious` at 60 seconds has appeared in runs whose results did not
differ, so a single thermal reading proves nothing on its own.

#### Long-film soak lane

Build 90 degraded over a long film on the Apple TV: subtitles fell
behind, and pause and a stop took about a minute at the 90-minute
mark. That is a backlog that grows for an hour, which no 60-second
bench window can see, so the trace gained what a whole film needs and
a hands-off lane drives it. That lane forces a subtitle track and
pauses, resumes and exits at controlled points along an otherwise
unattended run — ordinary calls into the engine, just scripted rather
than driven by a person, each printing how long its call took. With
`debug.decodeTrace` on, `DecodeTrace` adds what a growing backlog
would show up in: `mainLateMs` (how late the trace's own 2 s sleep
resumed, which reflects main-actor unavailability), `pumpMs` (a ping
through the pump queue), the cost and cadence of the engine's 10 Hz
`observeTime`, the subtitle store size (the embedded read-ahead
window keeps it from growing with the film), the renderer
notification-token count and thermal state, with `SoakWait` lines
timing the pause rate change, `pumpQueue.sync` and renderer
retirement.

91 minutes hands-off on a rebooted Apple TV 4K (3rd generation),
Release, a Dolby Vision profile 5 HEVC film with English CC on:
nothing grew. Footprint flat at 541 MB from ten minutes to ninety,
drop count and cue store linear in elapsed time, and four renderer
observers throughout. Zero stalls, zero audio dry-ups, zero
reprimes, and thermal nominal for the whole film. `mainLateMs` p99
was 99 ms, the 10 Hz tick never rose above 1.8 ms, and the pump ping
never rose above 2.2 ms. At 90 minutes pause returned in 72 ms,
resume in 40 ms, and the exit's `beginStop()` in 122 ms. So the
build-90 symptom does not reproduce on a build carrying the September
transport work: build 90 fetched the stream through libavformat's own
HTTP stack with GnuTLS. That layer is gone, and it is the one place a
100-minute backlog could have lived that this run cannot see.

Two things the run did show were not part of that long-film symptom:
a steady 0.66% drop rate with `opt=0` throughout (the known Dolby
Vision behaviour on this device, where every frame goes through
ordinary composition), and about 250 ms of every 2 s window spent on
the main thread with nothing on screen, which the observation-scope
split described later in this file addresses.

#### Where the composited-path drops come from (2026-09-10)

The soak's steady drop rate asked for the frame-loss bench rather
than a guess: same scene at 600 s, 10 s warm-up, 60 s window, five
minutes of cool-down, arms interleaved so heat and time of day could
not favour one, three runs each, Release. Three things fell out.

**The engine is never the bottleneck.** Zero stalls, zero audio
dry-ups and a decoded queue never below 29 of 30 in every arm.

**HDR output never reaches the renderer's optimized display path on
this device**, with or without anything drawn over it. A 1080p H.264
SDR title with 691 cues reaches it on 1457–1463 frames of 1465. Every
HDR arm reports zero. So every HDR frame goes through ordinary
composition.

**On that composited path the drops are the subtitle text layer.**
The same window drops six frames of about 1440 with a cue on screen
and zero with `benchSubtitleLanguage off` or `benchBareSurface`,
three runs each. HDR10 without Dolby Vision sits between at
0.14–0.21%. The cue's shadow edge and translucent background were
being filtered by Core Animation on every frame over a 4K HDR
composition, so each cue view is now a drawing group (`2590f57`),
rendered once per change and composited as one texture, with
`debug.benchFlatCues` keeping the old path for an A/B from the same
binary. Interleaved in one session that A/B gave 5 · 3 · 3 dropped
per window rasterized against 9 · 4 flat, roughly 40% fewer, not
zero. The remaining drops do not line up with cue arrivals, so what
is left is a layer-tree change over a 4K HDR frame rather than
per-frame filtering.

Both isolation hooks are load-bearing: `debug.benchSubtitleLanguage
off` because the system caption preference otherwise turns a track on
by itself, which silently invalidated the first "subtitles off" arm,
and `debug.benchBareSurface`, which removes everything above the
video.

#### The display path, measured with a paired device

What the layers measure, same hard scene (35–75 s of the 4K HDR10+
AV1 episode used above):

| where | what | result |
| --- | --- | --- |
| Mac | our vendored dav1d, direct | 177 fps (Homebrew's: 182 — build exonerated) |
| Mac | through our libavcodec, engine-style loop | 182 fps (wrapper exonerated) |
| Apple TV | same loop, bare test process | **55.7 fps** (hardware exonerated) |
| Apple TV | plus the P010 conversion | **39.7 fps** (enough, with margin) |
| Apple TV | plus holding a 25-frame queue | 39.6 fps (footprint free) |
| Apple TV | the host app, playing | **~20–22 fps** |

Apple defines the renderer's `optimized` counter as a special
power-efficient mode that avoids the usual UI composition. It is not
a generic "fast frame" counter
([`AVVideoPerformanceMetrics`](https://developer.apple.com/documentation/avfoundation/avvideoperformancemetrics)).
With the HUD off, hardware HEVC reached it on 87% of frames signalled
SDR and 0% signalled Dolby Vision. Software output reached 0% on
every linear PQ variant tried and 88% lossless-compressed and tagged
709. That justified testing the lossless-compressed SDR route, but it
did not prove that ordinary composition itself costs 20 ms.

#### Direct renderer P010 versus the transfer path

`AVSampleBufferVideoRenderer` accepts uncompressed image sample
buffers and exposes
[`recommendedPixelBufferAttributes`](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/recommendedpixelbufferattributes-6zrqb),
and Lagoon already built its linear pool from those attributes, so
the clean test was to bypass `VTPixelTransferSession` and enqueue the
final P010 buffer. Six accepted runs over the same segment,
interleaved, Release, three-run means: it is **worse**, 20.34%
dropped against 13.77% for lossless-compressed SDR. It really removes
about 9.8 ms of synchronous transfer work (conversion 2.82 against
12.62 ms/frame), but the libavcodec wait rises by about 7.8 ms (40.51
against 32.69), the starting footprint by about 359 MB (1305 against
946 MB), and more frames miss presentation. During direct-path bands
the renderer was ready, Lagoon's render queue was empty, and the
decoder still had about 30 packets pending: producer starvation, not
renderer backpressure or network starvation. The A/B changes linear
versus compressed storage, PQ versus SDR, and ordinary versus
optimized composition together, so it does not isolate which shared
resource feeds back into dav1d. The route is falsified for this
hardware either way. Production stays on lossless-compressed SDR, and
direct P010 remains a diagnostic control. A default transfer
configuration the device refuses falls back to linear output, while
an explicitly requested matrix mode fails at open rather than
silently benchmarking a different path.

The launch-argument parser for this route had to be fixed before any
of it could be trusted: `UserDefaults` stores `-key NO` as a
string-like value, so casting it with `as? Bool` had silently left
the transfer enabled. Check that before trusting any launch-flag A/B.

The same run proved the decoder configuration at runtime
(`codec="libdav1d" … lowDelay=off maxFrameDelay=0`). AV1 now requests
`libdav1d` by name instead of relying on registry order: the packaged
generic resolver had already selected it, but the explicit lookup
makes that invariant fail closed if a future FFmpeg package omits it.
`maxFrameDelay` is the requested dav1d option. The diagnostics also
report `AVCodecContext.delay`, which is the effective depth.

#### Where the CPU went, and the two fixes (resolved)

Everything above measured the decoder and the pipeline. What was
never measured was *who else was on the CPU*. `-debug.decodeTrace
YES` prints a `CPUTrace` line beside every `DecodeTrace` tick:
per-core busy percentages from `host_processor_info`, the process's
CPU time, and CPU time grouped by thread name from
`thread_info(THREAD_EXTENDED_INFO)`, with each group's scheduling
priority (`DecodeThreadDiagnostics.swift`). The decode queue tags its
own thread so it stands out among unnamed GCD workers. One tick of
the hard scene on the paired Apple TV, before any fix:

```
CPUTrace dt=2.02s coresBusy%=98/99/98/100/100 procMs=7331
  dav1d-worker=6125ms(x5 pri31/31) unnamed=990ms(x8 pri37/37)
  videodecode-q=133ms(x1 pri37/37) main=79ms(x1 pri47/47)
```

Read it as cores. The Apple TV 4K (3rd generation) is the binned A15
with **five** cores, two performance and three efficiency, and all
five were saturated. dav1d's five workers, at the default pthread
priority of 31, were getting 3.0 cores between them. Something
unnamed in the process was taking 0.5 of a core at a *higher*
priority, and 1.2 cores were going to other processes. That is the
entire host-app-versus-bare-process gap in the table above: the bare
loop had five cores and did 55 fps. The host app's decoder had three,
mostly efficiency ones, and did 22.

**The unnamed half core was the pump queue**, identified by reading
each unnamed thread's dispatch queue label. That was a one-off
diagnostic, since removed because it retained a dying queue, so do
not leave that reintroduced.
`AVSampleBufferVideoRenderer.requestMediaDataWhenReady` calls its
block whenever the renderer wants more, and *keeps calling it* for as
long as the block gives it nothing. The engine registered the block
once at attach and never stopped it, so whenever the video queue was
empty (which, with the decoder starving, was most of the hard scene)
the block ran in a loop at priority 47, the highest in the process,
enqueueing nothing. The audio block spun the same way on every
title, because the audio renderer takes audio as fast as it is
demuxed and the audio queue is empty almost always. The 1.2 cores in
other processes were the remote renderer answering that loop: they
fell to about 0.5 when it stopped. Disabling audio entirely
(`-debug.disableAudio YES`, diagnostic) changed nothing, which is how
audio decode was ruled out.

The fix is the one Apple's own sample code shows: a request is armed
only while there is something to give. A pump that finds its queue
empty calls `stopRequestingMediaData()`. `kickPumps()`, which already
runs whenever a queue receives a buffer, arms it again if the
renderer could not take everything at once (`armVideoRequests` /
`armAudioRequests` / `rearmRequestsIfNeeded`). This is not an AV1
fix. It applied to every title that ever played, and only mattered
once something else needed the CPU.

**The second fix takes the 12.5 ms of serial conversion off the
decode queue.** The CPU P010 repack and the VideoToolbox transfer
cost little CPU (the decode queue's own thread was 0.07 of a core),
but they ran synchronously between one `avcodec_send_packet` and the
next, so a frame cost `dav1d wait + 12.5 ms` and nothing could
overlap them. `MetalFrameConverter` replaces both with one compute
kernel (`SoftwareFrameConversion.metal`). dav1d's planar 10-bit frame
is wrapped in a no-copy `MTLBuffer` (FFmpeg's pooled 4K allocations
are page-aligned on Darwin, and the simulator's driver traps on that
and copies instead). The kernel repacks it to P010 and, for PQ
BT.2020 sources, tone-maps it to BT.709 SDR with the BT.2390 EETF at
203 nits reference white, writing straight into an IOSurface the
renderer takes on its direct display path (linear SDR P010 measures
66-73% optimized composition, the same as the transfer route, so the
GPU stage costs nothing there). **The dispatch is asynchronous on
purpose.** The decode queue submits and returns to libavcodec at
once, and the dav1d picture stays referenced until the kernel has
read it. Completions are resequenced into submission order by
`GPUDeliverySequencer`, because Metal serializes execution on one
command queue but promises nothing about the order or mutual
exclusion of the completion callbacks themselves. At most three
frames are in flight, and `flush()` / `drain()` wait for the GPU so
seeks and end of stream keep their old semantics. The output modes
are `gpu-sdr` (tvOS HDR default) and `gpu-pq` (the default elsewhere
for 10-bit sources). The transfer modes remain as fallbacks and
diagnostics, and a stream the kernel cannot serve (8-bit, HLG,
non-2020) degrades to its transfer equivalent at open.

This is why the GPU stage overlaps conversion with decode
successfully where moving the same work to a second CPU queue lost:
it costs *far less* CPU, not merely a different queue. Not *no* CPU
work, though. An earlier version of this note claimed that and was
wrong. Each frame still builds a command buffer and an encoder, makes
two texture-cache calls, flushes the cache and runs a completion
handler, plus a full staging copy on the simulator path. The claim is
a large reduction, not an absence.

Same scene, same window, same device, three-run production configuration
before and **one run after each step**:

| configuration | runs | dropped | stalls | min video queue | frame cost | cores busy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.1 (84) as shipped | 3 | 24.8% | 2 | 0 | 43.6 ms | 97-100% |
| + dav1d workers at `.userInitiated` | **1** | 21.5% | 2 | 0 | 42.1 ms | 99-100% |
| + GPU stage, synchronous | **1** | 25.6% | 2 | 0 | 43.3 ms | 97-100% |
| + pump fix and asynchronous GPU stage | **1** | **0.2%** | **0** | **29** | **1.4 ms** | **48-65%** |

> **Not yet replicated.** Only the baseline row meets CLAUDE.md's
> rule of three runs at a fixed position. The last row's effect is
> far too large to be run-to-run noise: it fell from 24.8% to 0.2%
> dropped, with the decoder switching from starved to backpressured.
> So the direction is not in doubt and the fix stays in, but treat
> 0.2%, 0 stalls, 1.4 ms and 48-65% as one sample each, and do not
> read the two middle rows as ranking anything at all.

The last row is 3 dropped frames in 1463 with the decoder throttled
by backpressure for the whole window (`producerStarved=0%`,
`downstreamBackpressure=100%`). dav1d's workers use 2.05 cores and
its wait per frame is under a millisecond because the queue is never
allowed to empty. Thermal state was nominal in every run, including
the failing ones, so throttling was never part of this.

Three things learned on the way are worth keeping.

**The kernel takes 8.7 ms of GPU time on the A15** (0.1-0.35 ms on a
Mac GPU), with a p99 near 40 ms while the CPU is loaded. Run
synchronously, it measured no better than the transfer it replaced.
Run asynchronously, it did not show up in the frame cost at all, and
its `pow`-heavy PQ and gamma math could move to lookup textures if
the GPU's power draw ever matters.

**Raising dav1d's workers to `.userInitiated`**
(`-debug.dav1dWorkerQoS`, applied through
`pthread_override_qos_class_start_np` on the threads named
`dav1d-worker`) gave dav1d more performance-core time and took
exactly that time from whatever else ran. Wait fell from 31 to 25 ms
while conversion rose from 12.6 to 16.7 ms, so reshuffling a
saturated CPU stays a diagnostic, not a fix.

**Apple's lossless-compressed P010 as a Metal destination** passes
texture creation and fails at the first dispatch on tvOS 26 / A15, so
`gpu-sdr` writes linear P010 and `-debug.softwareDecodeGPULossless
YES` proves a lossless request with one real conversion before
accepting it. Linear costs memory, a footprint near 1.67 GB with
about 430 MB of headroom on this title, which is what the 30-frame
byte budget was sized for.
(`-debug.softwareDecodeTargetNits`, default 203, is the SDR white
point of the tone map. The source peak comes from mastering metadata,
MaxCLL, or 1000 nits.)

What pins this against regression: `GPUDeliverySequencerTests` cover
the ordering guarantee, the in-flight cap, the bounded drain and the
failed-submission path. `MetalFrameConverterTests` run the kernel on
the simulator's GPU, where the repack must be exact and the tone map
must match a Double reference of its own arithmetic within two codes,
keep black black, reach white at the source peak, never invert a ramp
and leave grey neutral. The regression probe reports `videoPath`
(which output stage is live) and `idleRequests` (how often a
renderer's request block ran with nothing to give).
`testControlledFrameLossPlaybackPerformance` bounds that count per run
in the simulator, and
`testSoftwareDecodedPlaybackSurvivesPauseSeeksAndSubtitles` drives the
software-decoded fixture on a paired Apple TV through pause, seeks both ways
and a subtitle switch, asserting the GPU stage is the live path, playback
continues, the request blocks stay quiet and teardown is clean. Run it
against a real device, not the simulator, pointed at a title the
hardware decoder cannot take, so the fixture actually exercises
libavcodec and the GPU conversion stage:

```sh
xcodebuild test -destination 'platform=tvOS,id=<udid>' \
  -only-testing:<UI-test-target>/testSoftwareDecodedPlaybackSurvivesPauseSeeksAndSubtitles
```

It skips in the simulator, whose clock never starts on the fixture's
E-AC3 track, and it must run in Release. The Debug engine stalled
seven times through the same seeks where Release stalled none.
Restart the Apple TV first if a previous run was killed mid-playback.
A poisoned media daemon shows up as a media-services reset that
leaves the player paused.

#### Simulator sink ladder

`ApplePlaybackAlignmentTests.av1FixtureReportsDecodeOnlyAndOutputCeilings`
is an opt-in same-process benchmark. Set `LAGOON_AV1_FIXTURE_URL`
(and optionally `LAGOON_AV1_BENCHMARK_FRAMES`) in the test process
and it opens two fresh software decoders. The first receives and
unrefs dav1d frames without Core Video. The second runs the complete
P010/transfer/sample-buffer output. It reports external throughput
plus the decoder's own decode and conversion breakdown, which makes
the theoretical ceiling reproducible without a server session or
renderer.

#### dav1d frame-context depth

dav1d has two independent parallelism limits. `n_threads` creates
one shared worker pool. `max_frame_delay` limits the frame contexts
that pool may advance concurrently. It does **not** assign one
worker permanently to each picture. With an explicit value dav1d
uses `min(max_frame_delay, n_threads)`, while zero uses
`ceil(sqrt(n_threads))`. FFmpeg's libdav1d wrapper passes both
settings to `dav1d_open`, and marks the wrapper as
other-threaded/auto-thread-capable. The definitions are in
[dav1d's public header](https://github.com/videolan/dav1d/blob/master/include/dav1d/dav1d.h),
the resolution is in
[dav1d's scheduler setup](https://code.videolan.org/videolan/dav1d/-/blob/1.5.4/src/lib.c),
and the option bridge is in
[FFmpeg's wrapper](https://ffmpeg.org/doxygen/8.0/libdav1d_8c_source.html).

Lagoon previously configured five workers but left frame delay at
zero, so the Apple TV could advance only three pictures at once.
Production now requests a frame delay equal to the explicit worker
count before `avcodec_open2`: five workers and five frame contexts on
that device. `AV_CODEC_FLAG_LOW_DELAY` remains off. Zero remains an
explicit launch-argument control for dav1d's square-root default. The
diagnostic override is clamped to the useful worker depth, and
experiment values are parsed only from process arguments so that a
thread value persisted by an older build cannot silently reconfigure
production.

Depth three against depth five, five workers throughout, is worth
34-55%. The dav1d 1.5.4 CLI outside Lagoon (three runs per setting)
gained 43% on a 240-frame 4K 10-bit fixture and about 34% with
film-grain metadata. Lagoon's own libavcodec path in a Release arm64
tvOS simulator gained 47.7% decode-discard and 54.9% through complete
P010 output on a 2,400-frame fixture, and 38.2%/40.0% on a grain
fixture. The simulator cells are one long run each, so the direction
is solid and the percentages are one sample. It is also not
physical-device proof: the extra depth retains at least two more
aligned 3840x2176 YUV420P10 pictures (about 47.8 MiB before scratch
state) and may add two frame periods, about 83 ms at 23.976 fps, to
startup or seek latency, neither of which a simulator can score.

Two smaller changes rode along. On the transfer path the
CPU-written P010 buffer is unlocked before
`VTPixelTransferSessionTransferImage` and the source AVFrame released
immediately after the copy, which returns a roughly 24 MiB dav1d
picture earlier and keeps a Core Video CPU lock out of the
accelerator boundary. Fusing the luma and chroma work of the CPU
repack into one `concurrentPerform` cut p50 by about 5-6% and was
kept. The conversion-chunk count was not touched, because sweeping
one, two and three spanned 2.2% on one simulator run each, below what
this project treats as evidence.
