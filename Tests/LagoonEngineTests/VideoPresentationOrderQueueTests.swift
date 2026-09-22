import CoreMedia
import Testing
@testable import LagoonEngine

struct VideoPresentationOrderQueueTests {
    @Test func hierarchicalBFramesLeaveInStrictPresentationOrder() {
        var queue = VideoPresentationOrderQueue<Int>(depth: 4)
        let decodeOrder = [0, 4, 2, 1, 3, 5, 9, 7, 6, 8]
        var output: [Int] = []

        for frame in decodeOrder {
            if let ready = queue.append(
                frame,
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 24)
            ) {
                output.append(ready)
            }
        }
        output.append(contentsOf: queue.drain())

        #expect(output == Array(0...9))
    }

    @Test func resetDiscardsFramesFromTheOldSeekGeneration() {
        var queue = VideoPresentationOrderQueue<String>(depth: 2)
        _ = queue.append("old 2", presentationTimeStamp: CMTime(value: 2, timescale: 24))
        _ = queue.append("old 1", presentationTimeStamp: CMTime(value: 1, timescale: 24))

        queue.reset()
        _ = queue.append("new 1", presentationTimeStamp: CMTime(value: 1, timescale: 24))

        #expect(queue.drain() == ["new 1"])
    }

    @Test func equalAndInvalidTimestampsRemainStable() {
        var queue = VideoPresentationOrderQueue<String>(depth: 3)
        var output: [String] = []
        _ = queue.append("same first", presentationTimeStamp: CMTime(value: 1, timescale: 24))
        _ = queue.append("invalid first", presentationTimeStamp: .invalid)
        _ = queue.append("same second", presentationTimeStamp: CMTime(value: 1, timescale: 24))
        if let ready = queue.append("invalid second", presentationTimeStamp: .invalid) {
            output.append(ready)
        }
        output.append(contentsOf: queue.drain())

        #expect(output == ["same first", "same second", "invalid first", "invalid second"])
    }
}
