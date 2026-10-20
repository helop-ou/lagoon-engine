# Using the engine

The [README](../README.md#using-it) has the minimal setup. This guide covers
the rest.

`prepare` returns at once; opening and decoding run on their own queues. The
rest is what you would expect: `pause()`, `seek(to:)`, `setRate(_:)`,
`selectAudioTrack(id:)`, `selectSubtitleTrack(id:)`, and `shutdown()` when you
are done. Read `audioTracks` and `subtitleTracks` once playback has started.

## Buffering ahead

Name the media and say how it is delivered, and the engine puts a byte cache
in front of it: a sparse file filled ahead of the playhead once the picture is
up, paced so foreground reads get the link first. A stable file can be
cached; a segmented manifest cannot, and asking costs nothing.

```swift
engine.prepare(
    url: url,
    itemID: "episode-412",      // yours; the engine only matches on it
    delivery: .stableFile,
    expectedLength: sizeInBytes, // optional, saves a probe request
    startSeconds: 0,
    initialAudioOrdinal: nil
)
```

- `bufferState` has the buffered fraction and cached ranges, for a scrub bar,
  and the rate the link delivers while busy, to tell a slow link from
  anything else.
- `suspendBufferFill()` and `resumeBufferFill()` pause and resume filling
  without losing what is cached, for an app going to the background.
- `stageSuccessor` warms a second scope for what plays next. A later `prepare`
  with the same `itemID` and URL promotes it instead of starting over.
- There is one cache per process: one active scope and at most one staged
  successor, whichever engine is playing.

## Fetching media that needs a credential

Pass a `MediaRequestAuthorization`, and the engine sends the header with every
request, HLS playlists and segments included. Credentials never go into a URL
and are never logged. A server behind a forward-auth proxy can add the
proxy's headers with `additionalHeaders`; they go to the same origin only.

```swift
engine.prepare(
    url: url,
    startSeconds: 0,
    initialAudioOrdinal: nil,
    authorization: MediaRequestAuthorization(
        origin: serverURL,
        headerName: "Authorization",
        headerValue: token
    )
)
```

## Talking to it through the protocol

`SampleBufferPlayerEngine` conforms to `PlayerEngine`: everything a player UI
needs and nothing about FFmpeg. Bind your controls to the protocol, not the
class. For a HUD or crash reports, `PlayerEngineDiagnostics` is an optional
second surface with queue depths, frame counters and decode details.

Diagnostics are off by default. Install a sink with
`EngineDiagnostics.use(_:)`.
