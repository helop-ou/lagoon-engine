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
