# Engineering notes

The reasoning and the measurements behind [the engine
guide](../engine.md). The guide states a contract; these say why it is that
shape and what happens when it is not.

Some of these record experiments on a particular build. Where a figure is
quoted, it was measured rather than estimated — but the code may have moved
since, and a number without a date is worth re-measuring before it is trusted.

| Note | Covers |
| --- | --- |
| [Decode](decode.md) | The software decode pipeline, dav1d's arm64 assembly, the Metal conversion stage, thread and frame-delay tuning, how decode is measured on a device |
| [Queues and renderers](queues-and-renderers.md) | Demux loop threading, seek and clock starts, HDR and Dolby Vision tagging, profile 7 conversion, stall recovery, audio starvation |
| [Cache and teardown](cache-and-teardown.md) | The sparse range buffer, fill policy, hole punching, two-phase teardown and its lifecycle benchmarks |
| [Transport](transport.md) | The URLSession transport, the HLS scheme patch, certificate trust, disc image mounting |
| [Codecs](codecs.md) | Per-codec behaviour, zero-copy compressed packets, passthrough audio timing, deinterlacing, subtitle rendering and cue lifetime |
| [Stream recovery](stream-recovery.md) | Containers that describe no bitstream, seeks into an open GOP, a decode session the system reclaimed, what MPEG-TS breaks that no probe reports |
| [System integration](system-integration.md) | Audio session and spatialization, rate policy, output suspension, display-match requests, the counters behind a host's HUD |
| [Frame-loss bench](frame-loss-bench.md) | Decoded-frame memory ceilings, the P010 surface arithmetic, and the leak that produced them |

## Measurement

Never trust a casual frame-loss comparison. Content alone varies loss
threefold within one file, and taking a simulator screenshot forces a render
capture and drops frames. Compare the same scene over the same media-time
window, untouched, across three or more runs.

Two fixes in this engine's history were retracted after being measured across
different scenes, positions and sampling rates. That is where the rule comes
from.
