import Foundation

/// A disc image, addressed in bytes.
///
/// The volume reader asks for small scattered reads — descriptors,
/// directories, playlists — so an implementation is expected to cache rather
/// than fetch exactly what it is asked for. Over a network the whole mount
/// costs a handful of requests when it does.
nonisolated protocol DiscImageSource: AnyObject {
    /// The image's total length, when the transport knows it.
    var imageLength: Int64? { get }
    func read(at offset: Int64, count: Int) throws -> Data
}

nonisolated enum DiscImageError: LocalizedError, Equatable {
    /// No UDF filesystem at the anchor. A DVD image or a plain file lands
    /// here, and so does anything the reader should decline rather than guess
    /// at.
    case notUDF
    case unsupported(String)
    case malformed(String)
    case noTitle
    case resourceLimit

    var errorDescription: String? {
        switch self {
        case .notUDF:
            "The disc image has no UDF filesystem."
        case .unsupported(let detail):
            "The disc image uses \(detail), which this reader does not handle."
        case .malformed(let detail):
            "The disc image is malformed (\(detail))."
        case .noTitle:
            "The disc image has no playable title."
        case .resourceLimit:
            "The disc image's metadata exceeds the safe reading limits."
        }
    }
}

/// One budget for mounting AND selecting a title. Per-file limits alone let
/// hundreds of individually small files consume unbounded startup work.
/// Owned by the demux worker; cancellation is supplied by its locked flag.
nonisolated final class DiscReadBudget {
    static let maxReadBytes = 64 * 1_024
    private var bytesRemaining: Int
    private var readsRemaining: Int
    private var operationsRemaining: Int
    private let deadline: TimeInterval
    private let isCancelled: () -> Bool

    init(bytes: Int = 32 * 1_024 * 1_024, reads: Int = 2_048,
         operations: Int = 100_000, seconds: TimeInterval = 30,
         isCancelled: @escaping () -> Bool = { false }) {
        bytesRemaining = bytes
        readsRemaining = reads
        operationsRemaining = operations
        deadline = ProcessInfo.processInfo.systemUptime + seconds
        self.isCancelled = isCancelled
    }

    func check() throws {
        if isCancelled() { throw CancellationError() }
        guard operationsRemaining > 0, ProcessInfo.processInfo.systemUptime <= deadline else {
            throw DiscImageError.resourceLimit
        }
        operationsRemaining -= 1
    }

    func read(_ count: Int) throws {
        try check()
        guard count >= 0, count <= Self.maxReadBytes,
              count <= bytesRemaining, readsRemaining > 0 else {
            throw DiscImageError.resourceLimit
        }
        bytesRemaining -= count
        readsRemaining -= 1
    }
}

/// Ask the demuxer to read the media as a disc image rather than as a stream.
nonisolated struct DiscPlaybackRequest: Equatable {
    /// What the server says the film runs for. The strongest signal there is
    /// for picking the main title out of sixty-odd playlists, and one only a
    /// client talking to a media server ever has.
    let runtimeSeconds: Double?

    init(runtimeSeconds: Double?) {
        self.runtimeSeconds = runtimeSeconds
    }
}

/// One run of bytes inside the image.
nonisolated struct DiscExtent: Equatable {
    let offset: Int64
    let length: Int64
}

/// A title's extents laid end to end, as one addressable stream.
///
/// A Blu-ray main title is rarely one file. Seamless branching splits it
/// into dozens of clips — WALL·E's is 42 — and the filesystem fragments some
/// of those again, so the mapping has to be per extent rather than per file.
nonisolated struct DiscStreamMap: Equatable {
    static let maxExtents = 65_536
    let extents: [DiscExtent]
    /// Virtual start of each extent, parallel to `extents`.
    private let starts: [Int64]
    let length: Int64

    init(extents: [DiscExtent]) throws {
        guard extents.count <= Self.maxExtents else { throw DiscImageError.resourceLimit }
        var starts: [Int64] = []
        var total: Int64 = 0
        starts.reserveCapacity(extents.count)
        for extent in extents {
            guard extent.offset >= 0, extent.length > 0,
                  extent.length <= Int64.max - extent.offset,
                  extent.length <= Int64.max - total else {
                throw DiscImageError.malformed("invalid stream extent")
            }
            starts.append(total)
            total += extent.length
        }
        self.extents = extents
        self.starts = starts
        self.length = total
    }

    /// Where `offset` lands in the image, and how much can be read there
    /// before the next extent begins. nil past the end.
    ///
    /// Binary search rather than a walk: a fragmented title can carry
    /// hundreds of extents and this answers every read the demuxer makes.
    func locate(_ offset: Int64) -> (imageOffset: Int64, available: Int)? {
        guard offset >= 0, offset < length, !extents.isEmpty else { return nil }
        var low = 0
        var high = extents.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let within = offset - starts[low]
        let remaining = extents[low].length - within
        guard remaining > 0 else { return nil }
        return (extents[low].offset + within, Int(min(remaining, Int64(Int.max))))
    }
}

/// Little-endian field access with bounds that are checked rather than
/// trusted: every one of these reads is parsing bytes a server handed over,
/// and a malformed image must fail the open rather than the process.
nonisolated struct DiscBytes {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    var count: Int { data.count }

    func u8(_ offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < data.count else {
            throw DiscImageError.malformed("read past the end of a descriptor")
        }
        return data[data.startIndex + offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        try require(offset, 2)
        return UInt16(try u8(offset)) | (UInt16(try u8(offset + 1)) << 8)
    }

    func u32(_ offset: Int) throws -> UInt32 {
        try require(offset, 4)
        var value: UInt32 = 0
        for byte in 0..<4 {
            value |= UInt32(try u8(offset + byte)) << (8 * UInt32(byte))
        }
        return value
    }

    func u64(_ offset: Int) throws -> UInt64 {
        try require(offset, 8)
        var value: UInt64 = 0
        for byte in 0..<8 {
            value |= UInt64(try u8(offset + byte)) << (8 * UInt64(byte))
        }
        return value
    }

    func bytes(_ offset: Int, _ count: Int) throws -> Data {
        try require(offset, count)
        let start = data.startIndex + offset
        return data[start..<(start + count)]
    }

    func require(_ offset: Int, _ count: Int) throws {
        guard offset >= 0, offset <= data.count, count >= 0, count <= data.count - offset else {
            throw DiscImageError.malformed("read past the end of a descriptor")
        }
    }

    /// A UDF regid's identifier, which names things like the metadata
    /// partition.
    func identifier(_ offset: Int) throws -> String {
        try require(offset, 24)
        let raw = try bytes(offset + 1, 23)
        let trimmed = raw.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// A UDF d-character string: a compression byte then the characters.
    static func characters(_ raw: Data) -> String {
        guard let compression = raw.first else { return "" }
        let body = raw.dropFirst()
        switch compression {
        case 8:
            return String(decoding: body, as: UTF8.self)
        case 16:
            var scalars = String.UnicodeScalarView()
            var iterator = body.makeIterator()
            while let high = iterator.next(), let low = iterator.next() {
                let value = UInt32(high) << 8 | UInt32(low)
                scalars.append(Unicode.Scalar(value) ?? " ")
            }
            return String(scalars)
        default:
            return String(decoding: body, as: UTF8.self)
        }
    }
}
