# Contributing to Lagoon Engine

Lagoon Engine is the sample-buffer playback engine extracted from Lagoon, the
Jellyfin client for tvOS and iOS: a Swift package that demuxes, decodes and
renders media over vendored FFmpeg static libraries, with no AVPlayer path
and no third-party Swift dependency.

The licence is **MPL-2.0** for Lagoon Engine's own code, in
[LICENSE](LICENSE), with the Lagoon name and wordmark carved out of the grant
by [TRADEMARKS.md](TRADEMARKS.md). Contributions are made under those terms.
Bugs go through the issue form; anything with security or privacy impact
follows [SECURITY.md](SECURITY.md) instead of an issue. Everyone taking part
keeps to the [Code of Conduct](CODE_OF_CONDUCT.md), which is reported to
support@helop.dev.

## Prerequisites

macOS 26 and Xcode 26.6 (17F113) or newer. Xcode 26.6 built the vendored
native artifacts and older versions are untested. Nothing else is needed for
a normal build; rebuilding the native artifacts needs more, see [Native
artifacts](#native-artifacts).

## Clone and build

The package supports iOS and tvOS only, so build it against a simulator
destination rather than the host:

```sh
xcodebuild -scheme LagoonEngine -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme LagoonEngine -destination 'generic/platform=iOS Simulator' build
```

Run them one at a time. They share derived data, and running both at once
fails one of them with exit 65 and no useful diagnosis.

Bare `swift build` and `swift test` do not work, and are not expected to.
SwiftPM builds for the host, and `Package.swift` declares no macOS platform,
so the host build gets a default deployment target older than the APIs the
engine uses — `Duration`, and `os_proc_available_memory()`, which is
unavailable on macOS at any version. The failure looks like a broken checkout
and is not one.

The first build resolves the package's binary targets: some are
checksum-pinned artifacts from MPVKit, fetched over the network, and the rest
are the vendored xcframeworks in this repository.

## Tests

The unit suite covers the engine's pure logic, and runs on a booted simulator:

```sh
xcodebuild test -scheme LagoonEngine -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

## Commits

Work goes straight to `main`. Subjects are conventional and lowercase
imperative — `feat: move the demux, decode, render and transport core`, `fix:`, `chore:`,
`docs:` — with no scope parentheses. The house style is many small thematic
commits, usually one file each, ordered so every intermediate state builds. A
substantial `fix:` earns a body explaining the mechanism; a mechanical one
stays subject-only. Keep structural moves separate from behaviour changes.

## Releasing

The package's version is a git tag. SwiftPM reads it from there, and a
consumer has no way to ask what it resolved — so `EngineVersion.current`
carries the same number for a host to report, and the two move together:

```sh
# 1. set EngineVersion.current to the new version, and commit it
# 2. tag that commit, and push both
git tag 1.2.0
git push origin main 1.2.0
```

Real semantic versioning, because the package has real dependents: a
breaking change to anything `public` is a major bump. What counts as public
is decided by whether a host names a type or can reach it from one it does —
a type nothing outside can reach is internal, and changing it is not a
breaking change. Keep it that way and most releases stay minor.

A consumer pins a version range, so a release that does not build from a
clean checkout on both platforms is worse than no release. Build and test
both before tagging.

## Dependencies

This package takes no third-party Swift dependency, and that is deliberate.
A new one needs a real argument.

## Native artifacts

Three xcframeworks are vendored rather than fetched, and two are built here.
Each rebuild recipe sits beside its artifact, and both scripts have a
`--verify-only` mode that checks a packaged framework.

- libavformat, built without its network stack:
  [`Artifacts/Libavformat.README.md`](Artifacts/Libavformat.README.md). Needs
  Python 3.12+ and pkg-config.
- dav1d, built with its arm64 assembly kept: see the header comment of
  [`scripts/build-dav1d.sh`](scripts/build-dav1d.sh), which needs meson and
  ninja. Always run `scripts/build-dav1d.sh --verify-only
  Artifacts/Libdav1d.xcframework` after touching it: without the assembly it
  still decodes everything correctly, about ten times slower, and nothing
  fails.
- libdovi cannot be rebuilt in this repository. It is vendored prebuilt, and a
  from-source build needs a Rust toolchain and `cargo-c`. Provenance and
  per-slice hashes are in
  [`Artifacts/Libdovi.README.md`](Artifacts/Libdovi.README.md).
