import CoreMedia

/// Audio a video resume reads again. The container moves back to a keyframe
/// behind audio already queued; that audio must not play twice, and the
/// rest must follow it without a gap.
nonisolated enum AudioReplayTrim {
    /// Container stamps re-anchored after a reposition can differ from the
    /// first read by a rounding step.
    static let tolerance: Double = 0.002

    /// What of `buffer` comes after `floor`: all of it, the tail of a decoded
    /// buffer that straddles it, or nil. A compressed packet cannot be cut,
    /// so it stays only if most of it is new.
    static func remainder(of buffer: CMSampleBuffer, after floor: Double) -> CMSampleBuffer? {
        guard floor.isFinite else { return buffer }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let duration = CMSampleBufferGetDuration(buffer)
        guard pts.isValid, pts.seconds.isFinite, duration.isValid, duration.seconds > 0 else { return buffer }
        let start = pts.seconds
        let end = start + duration.seconds
        if end <= floor + tolerance { return nil }
        if start >= floor - tolerance { return buffer }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 1 else {
            return floor - start < (end - start) / 2 ? buffer : nil
        }
        let dropped = Int(((floor - start) / (end - start) * Double(count)).rounded())
        guard dropped > 0 else { return buffer }
        guard dropped < count else { return nil }
        var tail: CMSampleBuffer?
        guard CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleRange: CFRange(location: dropped, length: count - dropped),
            sampleBufferOut: &tail
        ) == noErr else { return nil }
        return tail
    }
}

/// Subtitle events a video resume reads again, told apart by their time and,
/// among events that share one, by how many had been read. A typeset ASS
/// script starts many events at the same instant, each in its own packet.
nonisolated enum SubtitleReplay {
    /// How far a stream has been read: the latest event time, and how many
    /// events at that time.
    struct Mark: Equatable {
        var time: Double
        var count: Int

        mutating func note(_ events: [SubtitleEvent]) {
            for event in events {
                let time = SubtitleReplay.time(of: event)
                if time > self.time {
                    self = Mark(time: time, count: 1)
                } else if time == self.time {
                    count += 1
                }
            }
        }
    }

    static func mark(after events: [SubtitleEvent], from mark: Mark?) -> Mark? {
        var mark = mark ?? Mark(time: -.infinity, count: 0)
        mark.note(events)
        return mark.count > 0 ? mark : nil
    }

    /// The events not read before the resume. `floor` is how far the stream
    /// had been read, and counts down the events at its time as they pass.
    static func unread(_ events: [SubtitleEvent], after floor: inout Mark?) -> [SubtitleEvent] {
        guard var remaining = floor else { return events }
        let unread = events.filter { event in
            let time = time(of: event)
            if time < remaining.time { return false }
            guard time == remaining.time, remaining.count > 0 else { return true }
            remaining.count -= 1
            return false
        }
        // Once past it, the floor has done its work.
        floor = unread.isEmpty ? remaining : nil
        return unread
    }

    static func time(of event: SubtitleEvent) -> Double {
        switch event {
        case .cue(let cue): cue.start
        case .clear(let seconds): seconds
        case .styledChunk(let chunk): Double(chunk.startMilliseconds) / 1_000
        }
    }
}
