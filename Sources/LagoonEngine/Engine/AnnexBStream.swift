import Foundation

/// Bitstreams that delimit NAL units with start codes (Annex B), such as
/// MPEG-TS from a Blu-ray's m2ts.
///
/// Both must be converted. libavformat hands MPEG-TS extradata over in Annex B;
/// read as an `hvcC`, `VTDecompressionSessionCreate` refuses it, which looks
/// like "no hardware decoder" but is a framing mismatch. And VideoToolbox
/// cannot decode samples carrying start codes.
nonisolated enum AnnexBStream {
    /// Length-prefix size. Four bytes: a 4K slice NAL outgrows three.
    static let nalUnitHeaderLength: Int32 = 4

    /// Codecs that arrive this way; each reads its NAL type from different bits.
    enum Codec {
        case hevc
        case h264

        /// Parameter sets in decoder order.
        var parameterSetTypes: [UInt8] {
            switch self {
            case .hevc: [32, 33, 34]    // VPS, SPS, PPS
            case .h264: [7, 8]          // SPS, PPS
            }
        }

        func nalType(_ header: UInt8) -> UInt8 {
            switch self {
            case .hevc: (header >> 1) & 0x3F
            case .h264: header & 0x1F
            }
        }
    }

    /// Whether extradata is start-code delimited. An `hvcC` or `avcC` record
    /// cannot be: both open with a version byte of 1.
    static func usesStartCodes(_ data: Data) -> Bool {
        let base = data.startIndex
        guard data.count >= 4 else { return false }
        if data[base] == 0, data[base + 1] == 0, data[base + 2] == 1 { return true }
        return data[base] == 0
            && data[base + 1] == 0
            && data[base + 2] == 0
            && data[base + 3] == 1
    }

    /// NAL unit ranges, excluding start codes. Emulation prevention means a
    /// start code cannot appear inside a NAL.
    static func nalUnits(in bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        var units: [Range<Int>] = []
        var start: Int?
        var index = 0
        let count = bytes.count
        while index + 2 < count {
            guard bytes[index] == 0, bytes[index + 1] == 0 else {
                index += 1
                continue
            }
            let codeLength: Int
            if bytes[index + 2] == 1 {
                codeLength = 3
            } else if index + 3 < count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                codeLength = 4
            } else {
                index += 1
                continue
            }
            if let start, index > start {
                units.append(start..<index)
            }
            index += codeLength
            start = index
        }
        if let start, start < count {
            units.append(start..<count)
        }
        return units
    }

    /// The NAL units length-prefixed, the only framing VideoToolbox accepts.
    /// nil when there are no NAL units.
    static func lengthPrefixed(_ bytes: UnsafeRawBufferPointer) -> Data? {
        let units = nalUnits(in: bytes)
        guard !units.isEmpty, let base = bytes.baseAddress else { return nil }
        var converted = Data(capacity: bytes.count + units.count * 4)
        for unit in units {
            let length = UInt32(unit.count)
            converted.append(UInt8(truncatingIfNeeded: length >> 24))
            converted.append(UInt8(truncatingIfNeeded: length >> 16))
            converted.append(UInt8(truncatingIfNeeded: length >> 8))
            converted.append(UInt8(truncatingIfNeeded: length))
            converted.append(
                Data(bytes: base.advanced(by: unit.lowerBound), count: unit.count)
            )
        }
        return converted
    }

    /// The parameter sets for a format description, in decoder order. nil
    /// unless all are present; the caller then falls back to the container's
    /// record.
    static func parameterSets(inAnnexB data: Data, codec: Codec) -> [Data]? {
        var found: [UInt8: Data] = [:]
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for unit in nalUnits(in: bytes) where unit.count > 1 {
                let type = codec.nalType(bytes[unit.lowerBound])
                guard codec.parameterSetTypes.contains(type), found[type] == nil else { continue }
                // Trim trailing zero padding, as muxers do.
                var length = unit.count
                while length > 1, bytes[unit.lowerBound + length - 1] == 0 {
                    length -= 1
                }
                found[type] = Data(bytes: base.advanced(by: unit.lowerBound), count: length)
            }
        }
        let ordered = codec.parameterSetTypes.compactMap { found[$0] }
        return ordered.count == codec.parameterSetTypes.count ? ordered : nil
    }
}
