# Changelog

Versions follow [semantic versioning](https://semver.org): a breaking change
to anything `public` is a major bump. What counts as public is decided by
whether a host names a type or can reach it from one it does, so a type
nothing outside the package can reach is internal and changing it is not a
breaking change.

This file is the source of truth for release notes, and
`scripts/publish-release.sh` reads the entry for the version it is tagging.
An entry is for somebody adopting or upgrading the package, not for a reader
of the diff.

## 1.0.1

September 2026. No API change. Upgrading is a version bump and nothing else.

### The package builds its own libavformat

`scripts/build-ffmpeg-format.py` no longer downloads MPVKit's
`Libavformat.xcframework` on every run. It used to fetch it for two things:
the list of muxers, demuxers, encoders and decoders to configure, read out of
that build's `config.h`, and the public headers to vend. Both now come from
the repository — the selection list is committed at
`scripts/ffmpeg-format-selections.txt` with its provenance, and the headers
are copied out of the FFmpeg source being compiled, so they cannot drift from
it.

The only thing the build downloads is FFmpeg's own checksum-pinned source
tarball. This matters if you build the artifact yourself, and it matters for
the project's ability to keep building at all: the script that exists to
rebuild libavformat independently could not itself run without a third
party's release staying up.

`Libavcodec`, `Libavutil`, `Libswresample`, `lcms2` and `Libuavs3d` are still
fetched from MPVKit as binary targets, and still carry upstream's
`--enable-version3` election. That is a separate piece of work.

### Building the package

`CONTRIBUTING.md` told you to run `swift build` and `swift test`. Neither
works, and neither ever did: the package declares iOS and tvOS only, so
SwiftPM's host build gets a macOS deployment target older than the APIs the
engine uses, and `os_proc_available_memory()` is unavailable on macOS at any
version. Build and test against a simulator destination instead; the
contributing guide now says so and explains why the failure is not a broken
checkout.

### The artifact

`Libavformat.xcframework` was rebuilt from FFmpeg n8.1.2 by the standalone
script. Same 131 codec selections, verified identical to the previous build,
and the same five public headers, verified byte-identical. `config.h` differs
only in the recorded build path and compiler version, which is the documented
non-reproducibility across Xcode versions.

## 1.0.0

September 2026. The first tagged release.

### The package

Demux, decode, render, queues, subtitles, the byte-source cache and the
vendored FFmpeg build, extracted from the Lagoon app and published as a
package another iOS or tvOS client can build a player on. Nothing in here
knows about Jellyfin, accounts or a branded interface.

### What a host talks to

`PlayerEngine` is the transport contract — a picture, a clock, track
selection and a verdict when playback fails. `PlayerEngineDiagnostics` is a
second, optional surface carrying queue depths, renderer counters and the
decode trace, so a host that only wants to play something never has to think
about them. `SampleBufferPlayerEngine` is the implementation behind both.

`prepare` takes a URL, an item identifier and a `MediaDelivery`, and the
engine decides for itself whether to put a byte cache in front of the bytes,
fills it ahead of the playhead once the picture is up, and warms a staged
successor for whatever the host expects to play next. `bufferState` is what a
scrub bar reads back.

### What a host configures

`EngineTuning` supplies the decode experiments, measurement switches and
cache overrides. Everything is off, empty or automatic by default, so a host
that installs nothing gets ordinary playback with no instrumentation. A host
installs a closure rather than a value, because several knobs are read afresh
at the start of each playback.

`EngineDiagnostics.use` installs a sink for the engine's own events and
incidents. Without one they are discarded: a library that reported by default
would be reporting to its author about somebody else's users.

`EngineVersion` carries this number and the linked libavformat, because
SwiftPM gives a consumer no way to ask what it resolved.

### Native dependencies

libavformat is built by this repository with its network stack compiled out —
HTTP goes through URLSession, which is also where certificate trust lives — so
the GnuTLS, GMP, nettle and hogweed static libraries are gone along with the
`--enable-version3` that GnuTLS's licence required. dav1d is built here too,
with its assembly kept: the upstream binary compiles it out, which put every
AV1 frame on the portable C path.

See the README for the full licence position and `Artifacts/` for the
rebuild recipes and provenance of each vendored framework.
