# Coding standards

Read this before adding a feature or reorganizing code. These are conventions
built on Apple and Swift guidance. [The engine guide](engine.md) describes how
the code behaves.

## Guidance from Apple and Swift

| Topic | Published guidance | How this package applies it |
| --- | --- | --- |
| Project organization | Group code by functionality and match it to the filesystem. [Great Developer Habits, WWDC19](https://developer.apple.com/videos/play/wwdc2019/239/) | Keep a stage's files together and mirror folders in the package. |
| Modules | Use local Swift packages to isolate suitable code. [Organizing code with local packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages) | This package is that boundary. Another one inside it needs the same argument. |
| API naming | Clarity at the call site, consistent naming. [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) | `UpperCamelCase` types, `lowerCamelCase` members, meaningful argument labels. |

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

Do not create empty folders to match the diagram, or generic `Utils`,
`Helpers` or `Common` folders.

## What belongs here, and what does not

Be strict about this line: every violation is a reason someone else cannot use
the package.

The engine is handed a media source, track metadata, an optional credential
and configuration. It demuxes, decodes, renders and reports what it observed.
It does not know:

- what server the media came from, or that there is a server;
- who the viewer is, or that there are accounts;
- what the host's settings offer, or what the viewer chose;
- whether anyone collects diagnostics;
- what the host will do when playback fails.

When it needs one of those, it takes an input or states a verdict and lets the
host decide. `PlaybackEngineFailure.Cause` is the model: the engine says
whether the samples were undecodable or the delivery failed, and the host
decides whether to ask for the media another way.

No type in `Sources/LagoonEngine` may name a media server's wire format.
`MediaDelivery` exists so the cache never reads a server's play-method enum.

## Files and reusable components

- Name a file after its main type. A small private helper can sit beside its
  only caller. One type per file is not absolute.
- Extract when responsibilities, state lifetime or callers differ. Line count
  is a prompt to review, not a limit, and not a reason to split a cohesive
  implementation into arbitrary extensions.
- Comment on why a constraint exists, especially ownership or timing. Delete
  dead and commented-out code; git keeps history. No session narratives in
  source.
- No ticket keys in comments or commit messages. Measurement runs, attempt
  counts and dates belong in `docs/reference/`.

## State, concurrency, and boundaries

- Respect the package's default `MainActor` isolation (`Package.swift`). Mark
  values that cross isolation boundaries explicitly. Do not add
  `@unchecked Sendable` or broaden isolation to silence the compiler; document
  and verify the real synchronization instead.
- Every asynchronous operation needs an owner, a cancellation behaviour and a
  policy for late results.
- Queues and C/AVFoundation resource lifetimes are explicit boundaries. A
  renderer's request block is armed only while its queue has something to
  give. Two-phase shutdown, bounded queues and renderer retirement are
  invariants: see [the engine guide](engine.md#lifecycle).

## The module boundary and the hot path

Swift does not inline across a module boundary unless a declaration is
`@inlinable`, and a host importing this package is across it. Measured on
`Deinterlacer.plane`, a per-pixel loop:

| | ms per 1920x1080 luma plane |
| --- | --- |
| Same module | 11.66 |
| Cross-module | 17.58 (+51%) |
| Cross-module, `@inlinable` | 11.70 |

The cost is lost specialisation, not call overhead: in-module, the optimiser
folds the literal `componentStride`, unrolls the inner scoring loop and removes
a per-pixel array literal.

So a declaration on a per-pixel or per-byte path that a host or another
module calls is `@inlinable`, with `@usableFromInline` on the helpers it
reaches. Nothing else is: `@inlinable` freezes a body into every consumer's
build and is a compatibility commitment.

Keep the Release coverage override on `LagoonPixelOps` in `Package.swift`.
Xcode instruments package targets for coverage even when the app's Release
configuration turns it off, and these are the per-pixel loops.

## Review and verification

Keep structural moves separate from behaviour changes. After moving code,
check access control, resource paths and both platform builds, one at a time
(they share derived data, and running both at once fails one with no useful
diagnosis):

```
xcodebuild -scheme LagoonEngine -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme LagoonEngine -destination 'generic/platform=iOS Simulator' build
```

Run the tests, and add coverage for new logic or a regression. Do not add
tests that restate a file move.

Never trust a casual frame-loss comparison; the rules are in [the notes
index](reference/README.md#measurement). Measuring end to end needs a host
app, so the procedure lives with the host. The ceilings the engine enforces
are in [the frame-loss notes](reference/frame-loss-bench.md).

After touching dav1d, run `scripts/build-dav1d.sh --verify-only
Artifacts/Libdav1d.xcframework`. Without its arm64 assembly nothing fails;
everything just decodes about ten times slower.
