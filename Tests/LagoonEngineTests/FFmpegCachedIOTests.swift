import Foundation
import Libavformat
import Testing
@testable import LagoonEngine

@Suite("Native cached I/O bounds")
struct FFmpegCachedIOTests {
    @Test func overflowingNativeSeeksLeaveTheCursorUnchanged() throws {
        let io = try FFmpegCachedIO(source: MalformedByteSource())
        defer { io.close() }
        let context = try #require(io.context).pointee
        let seek = try #require(context.seek)
        #expect(seek(context.opaque, Int64.max - 1, SEEK_SET) == Int64.max - 1)
        #expect(seek(context.opaque, 10, SEEK_CUR) == -1)
        #expect(seek(context.opaque, 0, SEEK_CUR) == Int64.max - 1)
        #expect(seek(context.opaque, 1, SEEK_END) == -1)
        #expect(seek(context.opaque, Int64.min, SEEK_CUR) == -1)
        #expect(seek(context.opaque, 0, SEEK_SET) == 0)
    }

    @Test func oversizedReadCannotOverwriteTheNativeBuffer() throws {
        let io = try FFmpegCachedIO(source: MalformedByteSource())
        defer { io.close() }
        let context = try #require(io.context).pointee
        let read = try #require(context.read_packet)
        var buffer = [UInt8](repeating: 0xCC, count: 16)
        let status = buffer.withUnsafeMutableBufferPointer { read(context.opaque, $0.baseAddress, 8) }
        #expect(status == -5)
        #expect(buffer.allSatisfy { $0 == 0xCC })
    }

    @Test func readCannotOverflowTheNativeCursor() throws {
        let io = try FFmpegCachedIO(source: MalformedByteSource(extraBytes: 0))
        defer { io.close() }
        let context = try #require(io.context).pointee
        let seek = try #require(context.seek)
        let read = try #require(context.read_packet)
        #expect(seek(context.opaque, Int64.max, SEEK_SET) == Int64.max)
        var buffer = [UInt8](repeating: 0xCC, count: 8)
        let status = buffer.withUnsafeMutableBufferPointer { read(context.opaque, $0.baseAddress, 8) }
        #expect(status == -5)
        #expect(buffer.allSatisfy { $0 == 0xCC })
        #expect(seek(context.opaque, 0, SEEK_CUR) == Int64.max)
    }
}

private nonisolated final class MalformedByteSource: FFmpegByteSource {
    let requestSize: Int64 = 65_536
    let contentLength: Int64? = .max
    let extraBytes: Int
    init(extraBytes: Int = 1) { self.extraBytes = extraBytes }
    func read(offset: Int64, length: Int, priority: Float) throws -> Data {
        Data(repeating: 0, count: length + extraBytes)
    }
    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double) {}
}
