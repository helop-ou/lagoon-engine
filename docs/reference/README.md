# Engineering notes

The mechanism and measurements behind [the engine guide](../engine.md). The
guide states the contract; these say why. Figures were measured, not
estimated, but the code may have moved since: re-measure an undated number
before trusting it.

| Note | Covers |
| --- | --- |
| [Decode](decode.md) | The software decode pipeline, dav1d's arm64 assembly, the Metal conversion stage, thread and frame-delay tuning, measuring on a device |
| [Queues and renderers](queues-and-renderers.md) | Demux threading, seeks and clock starts, HDR and Dolby Vision tagging, profile 7 conversion, stall recovery, audio starvation |
| [Cache and teardown](cache-and-teardown.md) | The sparse range buffer, fill policy, hole punching, two-phase teardown and its lifecycle benchmarks |
| [Transport](transport.md) | The URLSession transport, the HLS scheme patch, certificate trust, disc image limits |
| [Codecs](codecs.md) | Per-codec behaviour, zero-copy packets, audio timing, deinterlacing, subtitle rendering and cue lifetime |
| [Stream recovery](stream-recovery.md) | Containers that describe no bitstream, open-GOP seeks, reclaimed decode sessions, disc images, MPEG-TS quirks |
| [System integration](system-integration.md) | Audio session and spatialization, rate policy, output suspension, display-match requests, HUD counters |
| [Frame-loss bench](frame-loss-bench.md) | Decoded-frame memory ceilings, the P010 arithmetic, and the leak behind them |

## Measurement

Never trust a casual frame-loss comparison. Loss varies threefold within one
file, and a simulator screenshot forces a render capture that drops frames.
Compare the same scene over the same media-time window, untouched, across
three or more runs. Two fixes in this engine's history were retracted after
being measured across different scenes, positions and sampling rates.
