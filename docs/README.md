# Documentation

Read [Coding standards](standards.md) first, then [the engine
guide](engine.md) before changing anything in `Sources/LagoonEngine`.

| Guide | Use it for |
| --- | --- |
| [Coding standards](standards.md) | Folder structure, the package boundary, concurrency, the hot path, verification |
| [The engine](engine.md) | What the package guarantees: pipeline, transport, lifecycle, memory, failure verdicts, diagnostics |
| [Codec support](codec-support.md) | What decodes, and by which path. Generated: edit `EngineCodecSupport` |

## Supporting material

- [`reference/`](reference/README.md): the engineering notes behind the
  guides, with the mechanism and measurements. Some record experiments on a
  specific build. Read them for reasoning; read the guides for the contract.
- `Artifacts/`: the native libraries and their provenance. See
  [FFmpeg](../Artifacts/FFmpeg.README.md),
  [libdovi](../Artifacts/Libdovi.README.md), and the header of each
  `scripts/build-*` script. Everything is built here except libdovi, which
  needs a Rust toolchain this repository does not carry.

## Keeping this clean

- When you change a contract, update the guide that owns it.
- Give each rule one home and link to it from elsewhere.
- Long investigations go in `reference/`.
- Validation evidence (revision, environment, result, what is still owed)
  belongs where the work is tracked, not in a guide.
