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

/// Subtitle events a video resume reads again, told apart by their time.
nonisolated enum SubtitleReplay {
    /// The events after `floor`, the latest one read before the resume.
    static func unread(_ events: [SubtitleEvent], after floor: Double?) -> [SubtitleEvent] {
        guard let floor else { return events }
        return events.filter { time(of: $0) > floor }
    }

    static func time(of event: SubtitleEvent) -> Double {
        switch event {
        case .cue(let cue): cue.start
        case .clear(let seconds): seconds
        case .styledChunk(let chunk): Double(chunk.startMilliseconds) / 1_000
        }
    }
}
