# Documentation

Start with [Coding standards](standards.md), then read [the engine
guide](engine.md) before changing anything in `Sources/LagoonEngine`.

| Guide | Use it for |
| --- | --- |
| [Coding standards](standards.md) | Folder structure, the package boundary, concurrency, the hot path, verification |
| [The engine](engine.md) | What the package guarantees: pipeline, transport, lifecycle, memory, failure verdicts, diagnostics |
| [Codec support](codec-support.md) | What decodes, and by which path. Generated — edit `EngineCodecSupport` |

## Supporting material

[`reference/`](reference/README.md) holds the longer engineering notes behind
the guides — the mechanism and the measurements behind a particular
implementation. Some describe experiments on a specific build, and the code
may have moved on since. Read them for reasoning and evidence; read the guides
for the contract.

`Artifacts/` carries the vendored native libraries and their provenance. Each
records where it came from and how to rebuild it:
[libavformat](../Artifacts/Libavformat.README.md) and
[libdovi](../Artifacts/Libdovi.README.md). libavformat and dav1d are built by
this repository; libdovi is vendored, because rebuilding it needs a Rust
toolchain this repository does not carry.

## Keeping this clean

Update the guide that owns a contract when you change it. Give each rule one
home and link to it from anywhere else it matters. Long technical
investigations go in `reference/`.

Validation evidence — the revision, the environment, the result, and what is
still owed — belongs wherever the work is tracked, not appended to a guide as
a session transcript.
