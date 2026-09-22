# Lagoon Engine — session notes

A sample-buffer playback engine for iOS 26 and tvOS 26, as one Swift package
over vendored FFmpeg static libraries. There is no AVPlayer path and no
third-party Swift dependency. Extracted from the Lagoon app, which is now one
host among any others.

## Where the rules live

`AGENTS.md` is a symlink to this file, so Codex and other agents read the same
instructions. Edit CLAUDE.md, never the link.

**Start at [docs/README.md](docs/README.md), follow the [coding
standards](docs/standards.md), and read [the engine
guide](docs/engine.md) before changing anything under
`Sources/LagoonEngine`.** This file is a map and a session checklist, not a
second copy of the guides. If a line here disagrees with a guide, the guide is
right and this file needs fixing.

| Guide | Owns |
| --- | --- |
| [Coding standards](docs/standards.md) | Folder structure, the package boundary, concurrency, the hot path, verification |
| [The engine](docs/engine.md) | Pipeline, transport, lifecycle, memory, failure verdicts, external clock hooks, diagnostics |
| [Engineering notes](docs/reference/README.md) | The mechanism and the measurements behind each contract |

## Session workflow

- Build, and keep both destinations green:

  ```
  xcodebuild -scheme LagoonEngine -destination 'generic/platform=tvOS Simulator' build
  xcodebuild -scheme LagoonEngine -destination 'generic/platform=iOS Simulator' build
  ```

  Never run the two at once. They share derived data, and one fails with exit
  65 and no useful diagnosis.

- The native libraries are the only dependency, and they are vendored here. Do
  not add a Swift dependency without serious deliberation.
- Report only what was verified. Before saying a change is done, run the
  builds and the relevant tests, and say what ran. If a step was skipped or a
  check failed, say so and show the output. Never describe an unrun check as
  passed.

## The boundary this package exists to hold

Nothing in `Sources/LagoonEngine` may know about a media server, an account, a
settings screen, a diagnostics service, or what a host does when playback
fails. When the engine needs one of those it takes an input or states a
verdict.

The rule and its reasoning are in [standards](docs/standards.md#what-belongs-here-and-what-does-not).
A violation is not a style problem: it is the reason someone else cannot use
this package.

## Invariants that have regressed before

Each is explained, with its evidence, in the guide named. This list exists so
you know to read that guide before touching the area.

- **Lifecycle** — [engine guide](docs/engine.md#lifecycle). Never revive a
  stopped engine or overlap two pipelines because teardown timed out. Stop is
  two-phase. A host holds the engine weakly from anything SwiftUI retains, and
  closures handed to SwiftUI never capture an engine.
- **Memory and queues** — [engine guide](docs/engine.md#memory). A renderer's
  request block is armed only while its queue has something to give. A frame
  count alone is not a memory budget. Decoded LPCM is copied into
  CoreMedia-owned storage at emit.
- **The delivery verdict** — [engine guide](docs/engine.md#verdicts-not-decisions).
  The ladder descends only on a verdict about the samples: a lost
  VideoToolbox session is rebuilt rather than declared undecodable, and while
  video output is suspended a failure is ignored outright.
- **Software decode** — [decode notes](docs/reference/decode.md).
  Software-decoded 10-bit video reaches the renderer through the asynchronous
  `MetalFrameConverter`. Making that synchronous changes its performance
  characteristics.
- **Vendored FFmpeg** — [engine guide](docs/engine.md#network-transport).
  libavformat is built here without its network stack, and every HTTP open
  goes through `FFmpegNetworkTransport` over URLSession; keep the build script
  and the artifact in sync. dav1d is built here and must keep its arm64
  assembly — run `scripts/build-dav1d.sh --verify-only
  Artifacts/Libdav1d.xcframework` after touching it, because without the
  assembly nothing fails, everything just decodes about ten times slower.
  libdovi is vendored rather than built, for the Dolby Vision profile 7 → 8.1
  conversion.
- **The module boundary** — [standards](docs/standards.md#the-module-boundary-and-the-hot-path).
  A per-pixel or per-byte declaration a host calls is `@inlinable`, with
  `@usableFromInline` on its helpers. Measured: 51% slower without it. Keep
  the Release coverage override on `LagoonPixelOps`.
- **Measurement** — [engineering notes](docs/reference/README.md#measurement).
  Never trust a casual frame-loss comparison. Same scene, same media-time
  window, untouched, three or more runs. Two fixes that skipped this were
  later retracted.

## Working with subagents

Use subagents where they make sense, and do the small things yourself.

Delegate a broad search across many files, independent pieces that can run in
parallel, a sweep of several guides, a set of mechanical edits with a precise
spec, or a review that benefits from fresh eyes on a diff. Give each agent a
precise spec and check what comes back. The main session plans, reviews and
verifies.

Do the work yourself when it is a single-file edit, a lookup in a file or
symbol you already know, or anything where explaining the task would take
longer than doing it. Never claim an agent's result before it has come back.
