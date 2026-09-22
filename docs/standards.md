# Coding standards

Read this before adding a feature or reorganizing code. The folder names, file
rules and boundaries are conventions built on Apple and Swift guidance, not an
Apple-mandated template. [The engine guide](engine.md) describes how the
current checkout behaves.

## Guidance from Apple and Swift

| Topic | Published guidance | How this package applies it |
| --- | --- | --- |
| Project organization | Apple recommends grouping code by functionality and matching it to the filesystem. [Great Developer Habits, WWDC19](https://developer.apple.com/videos/play/wwdc2019/239/) | Keep a stage's related files together and mirror folders in the package. |
| Modules | Apple recommends local Swift packages to isolate suitable code and improve reuse and maintenance. [Organizing code with local packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages) | This package is that boundary. Adding another one inside it needs the same argument. |
| API naming | Swift emphasizes clarity at the call site and consistent type/member naming. [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) | Descriptive `UpperCamelCase` types and `lowerCamelCase` members with meaningful argument labels. |

## Folder structure

```text
Sources/
  LagoonEngine/
    Engine/                  Demux, decode, render, and the engine's own verdicts
    Transport/               Byte sources, network transport, cache, disc images
    Subtitles/               Parsing, decoding, and cue lifetime
    Diagnostics/             Traces, counters, benchmarks, the sink protocol
  _LagoonFFmpeg/             Umbrella over the native libraries
  LagoonPixelOps/            SIMD pixel primitives, in C
Artifacts/                   Vendored xcframeworks and their provenance
Patches/                     Patches applied to upstream sources
scripts/                     Native build and verification scripts
```

Do not create empty folders to resemble the diagram. Avoid generic `Utils`,
`Helpers` or `Common` dumping grounds.

## What belongs here, and what does not

This is the line the package exists to hold, and it is worth being strict
about, because every violation of it is a reason someone else cannot use this.

The engine is handed a media source, track metadata, an optional credential
and configuration. It demuxes, decodes, renders, and reports what it observed.
It does not know:

- what server the media came from, or that there is a server at all;
- who the viewer is, or that there are accounts;
- what the host's settings screens offer, or what a viewer chose in them;
- whether anyone is collecting diagnostics;
- what the host will do when playback fails.

When the engine needs something from that list, it takes it as an input or
states a verdict and lets the host decide. `PlaybackEngineFailure.Cause` is
the model: the engine says whether the samples were undecodable or the
delivery failed, and the host decides whether to ask for the media another
way. The engine does not know what other ways exist.

No type in `Sources/LagoonEngine` may name a media server's wire format. That
rule is what `MediaDelivery` exists for: Jellyfin's `PlayMethod` used to be
read directly inside the cache, which put one server's enum in the decode
path.

## Files and reusable components

- Name a file after its main type. A small private helper can stay beside its
  only caller. One type per file is not an absolute rule.
- Extract when responsibilities, state lifetime or callers differ. A large
  line count is a signal to review, not a hard limit, and not a reason to
  split a cohesive implementation into arbitrary extensions.
- Comment on the reason for a constraint, especially ownership or timing.
  Remove dead code; git keeps the history. Do not leave session narratives or
  commented-out code in active source files.
- Keep ticket keys out of comments and commit messages. A comment explains the
  constraint it guards. Measurement runs, attempt counts and dates belong in
  `docs/reference/`, where they can be kept current.

## State, concurrency, and boundaries

- Respect the package's default `MainActor` isolation, declared in
  `Package.swift`. Mark values that cross isolation boundaries explicitly and
  preserve their safety. Do not add `@unchecked Sendable` or broaden isolation
  to shortcut a compiler error; document and verify the actual synchronization
  contract instead.
- Every asynchronous operation needs an owner, a cancellation behaviour and a
  policy for late results.
- Queues and C/AVFoundation resource lifetimes are explicit boundaries. A
  renderer's request block is armed only while its queue has something to
  give. Two-phase shutdown, bounded queues and renderer retirement are
  invariants, not implementation details — [the engine
  guide](engine.md#lifecycle) has the evidence.

## The module boundary and the hot path

Swift does not inline across a module boundary unless a declaration is
`@inlinable`, and a host importing this package is across that boundary.
Measured on `Deinterlacer.plane`, a per-pixel loop, in September 2026:

| | ms per 1920x1080 luma plane |
| --- | --- |
| Same module | 11.66 |
| Cross-module | 17.58 (+51%) |
| Cross-module, `@inlinable` | 11.70 |

The cost is not call overhead — the boundary is crossed once per plane. It is
lost specialisation: `componentStride` is a literal at every call site, and
in-module the optimiser folds it, unrolling the innermost scoring loop and
eliminating a per-pixel array literal.

So: a declaration on a per-pixel or per-byte path that a host calls, or that
is called from another module, is `@inlinable`, with `@usableFromInline` on
the helpers it reaches. Everything else is not — `@inlinable` freezes a body
into every consumer's build and is a compatibility commitment, so it is for
the hot path and nowhere else.

Keep the Release coverage override on `LagoonPixelOps` in `Package.swift`.
Xcode enables coverage instrumentation for package targets even when the
containing app's Release configuration disables it, and these are the
per-pixel loops.

## Review and verification

Keep structural moves separate from behaviour changes. After moving code,
verify access control, resource paths and both platform builds:

```
xcodebuild -scheme LagoonEngine -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme LagoonEngine -destination 'generic/platform=iOS Simulator' build
```

Run them one at a time. They share derived data, and running both at once
makes one fail with no useful diagnosis.

Run the existing tests and add coverage for new logic or a regression. Do not
add tests that restate a file move.

Never trust a casual frame-loss comparison. Same scene, same media-time
window, untouched, three or more runs. Two fixes in this engine's history were
retracted after being measured across different scenes and sampling rates.
Measuring end to end needs a host application to play media, so the procedure
lives with the host; the ceilings the engine enforces are in [the frame-loss
notes](reference/frame-loss-bench.md).

After touching dav1d, run `scripts/build-dav1d.sh --verify-only
Artifacts/Libdav1d.xcframework`. Without its arm64 assembly nothing fails —
everything just decodes about ten times slower.
