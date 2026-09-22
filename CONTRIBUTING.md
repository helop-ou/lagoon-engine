# Contributing to Lagoon Engine

Lagoon Engine is the sample-buffer playback engine extracted from Lagoon, the
Jellyfin client for tvOS and iOS: a Swift package that demuxes, decodes and
renders media over vendored FFmpeg static libraries, with no AVPlayer path
and no third-party Swift dependency.

- Lagoon Engine's own code is **MPL-2.0** ([LICENSE](LICENSE)). The Lagoon
  name and wordmark are carved out by [TRADEMARKS.md](TRADEMARKS.md).
  Contributions are made under those terms.
- Bugs go through the issue form. Anything with security or privacy impact
  follows [SECURITY.md](SECURITY.md) instead.
- Everyone keeps to the [Code of Conduct](CODE_OF_CONDUCT.md); report
  breaches to support@helop.dev.

## Prerequisites

macOS 26 and Xcode 26.6 (17F113) or newer. Xcode 26.6 built the vendored
native artifacts; older versions are untested. Nothing else is needed for a
normal build. Rebuilding the native artifacts needs more: see [Native
artifacts](#native-artifacts).

## Clone and build

The package supports iOS and tvOS only, so build against a simulator
destination:

```sh
xcodebuild -scheme LagoonEngine -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme LagoonEngine -destination 'generic/platform=iOS Simulator' build
```

Run them one at a time. They share derived data, and running both at once
fails one with exit 65 and no useful diagnosis.

Bare `swift build` and `swift test` do not work, by design. SwiftPM builds for
the host, and with no macOS platform declared it gets a deployment target
older than the APIs the engine uses (`Duration`, and
`os_proc_available_memory()`, which macOS lacks at any version). It looks
like a broken checkout and is not one.

Every binary target is an xcframework in this repository, so resolving the
package downloads nothing.

## Tests

The unit suite covers the engine's pure logic and runs on a booted simulator:

```sh
xcodebuild test -scheme LagoonEngine -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

## Commits

- Work goes straight to `main`.
- Subjects are conventional and lowercase imperative, with no scope
  parentheses: `feat: move the demux, decode, render and transport core`,
  `fix:`, `chore:`, `docs:`.
- Many small thematic commits, usually one file each, ordered so every
  intermediate state builds. One mechanical change across many files is one
  commit.
- Subject line only. Reasoning that needs a paragraph goes in the
  documentation, where it can be found and kept current.
- Keep structural moves separate from behaviour changes.

## Releasing

The package version is a git tag. A consumer cannot ask SwiftPM what it
resolved, so `EngineVersion.current` carries the same number for a host to
report. The two move together:

```sh
# 1. set EngineVersion.current to the new version, and commit it
# 2. tag that commit, and push both
git tag 1.2.0
git push origin main 1.2.0
```

Real semantic versioning: a breaking change to anything `public` is a major
bump. Public means a host names the type or can reach it from one it does; a
type nothing outside can reach is internal, and changing it is not breaking.

A consumer pins a version range, so a release that does not build from a
clean checkout on both platforms is worse than no release. Build and test both
before tagging.

## Dependencies

No third-party Swift dependency, deliberately. A new one needs a real
argument.

## Native artifacts

Every native library is an xcframework in this repository, and all but
libdovi are built here. Each build script has a `--verify-only` mode that
checks a packaged framework. Build in this order, because libavcodec links the
first three:

- **dav1d, lcms2, uavs3d**: `scripts/build-dav1d.sh`, `scripts/build-lcms2.sh`,
  `scripts/build-uavs3d.sh`, with provenance in each header comment. dav1d and
  lcms2 need meson and ninja; uavs3d needs only Xcode. dav1d keeps its arm64
  assembly: always run `scripts/build-dav1d.sh --verify-only
  Artifacts/Libdav1d.xcframework` after touching it. Without the assembly it
  still decodes correctly, about ten times slower, and nothing fails.
- **libavutil, libavcodec, libavformat, libswresample**: one configure, no
  network stack. See [`Artifacts/FFmpeg.README.md`](Artifacts/FFmpeg.README.md).
  Needs Python 3.12+ and pkg-config.
- **libdovi** cannot be rebuilt here. It is vendored prebuilt; a from-source
  build needs a Rust toolchain and `cargo-c`. Provenance and per-slice hashes
  are in [`Artifacts/Libdovi.README.md`](Artifacts/Libdovi.README.md).
