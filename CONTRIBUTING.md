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

Clone the repository and build with Swift Package Manager:

```sh
swift build
```

The first build resolves the package's binary targets: some are
checksum-pinned artifacts from MPVKit, fetched over the network, and the rest
are the vendored xcframeworks in this repository.

## Tests

The unit suite covers the engine's pure logic:

```sh
swift test
```

## Commits

Work goes straight to `main`. Subjects are conventional and lowercase
imperative — `feat: move the demux, decode, render and transport core`, `fix:`, `chore:`,
`docs:` — with no scope parentheses. The house style is many small thematic
commits, usually one file each, ordered so every intermediate state builds. A
substantial `fix:` earns a body explaining the mechanism; a mechanical one
stays subject-only. Keep structural moves separate from behaviour changes.

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
