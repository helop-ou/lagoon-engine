import Foundation

/// Recent events of every embedded text subtitle stream, selected or not, so
/// choosing one shows the line already on screen without a seek.
///
/// A seek to re-demux them would flush the video on the main actor, and would
/// still miss a line that started before the keyframe it lands on. Text
/// streams are tiny and interleaved with what the demuxer reads anyway, so
/// keeping them costs nothing but memory, which the window and the limit
/// bound. Bitmap streams (PGS) are not kept.
///
/// Not thread-safe: the engine holds it under its state lock.
nonisolated struct SubtitleBacklog {
    /// How far behind the newest event of a stream its events are kept.
    static let window: Double = 120
    /// Events per stream, past which the oldest go.
    static let limit = 4_096

    private struct Entry {
        let end: Double
        let event: SubtitleEvent
    }

    private var streams: [Int32: [Entry]] = [:]

    mutating func record(_ events: [SubtitleEvent], streamIndex: Int32) {
        guard !events.isEmpty else { return }
        var entries = streams[streamIndex] ?? []
        var newest = -Double.infinity
        for event in events {
            let (start, end) = Self.span(of: event)
            newest = max(newest, start)
            entries.append(Entry(end: end, event: event))
        }
        let horizon = newest - Self.window
        entries.removeAll { $0.end < horizon }
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
        streams[streamIndex] = entries
    }

    /// In the order they were demuxed.
    func events(for streamIndex: Int32) -> [SubtitleEvent] {
        streams[streamIndex]?.map(\.event) ?? []
    }

    func count(for streamIndex: Int32) -> Int {
        streams[streamIndex]?.count ?? 0
    }

    /// On a seek, which re-demuxes from the new position, and on a new open.
    mutating func removeAll() {
        streams.removeAll(keepingCapacity: true)
    }

    private static func span(of event: SubtitleEvent) -> (start: Double, end: Double) {
        switch event {
        case .cue(let cue):
            (cue.start, cue.end)
        case .clear(let seconds):
            (seconds, seconds)
        case .styledChunk(let chunk):
            (
                Double(chunk.startMilliseconds) / 1000,
                Double(chunk.startMilliseconds + chunk.durationMilliseconds) / 1000
            )
        }
    }
}
