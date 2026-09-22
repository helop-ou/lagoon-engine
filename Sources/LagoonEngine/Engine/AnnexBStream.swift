import Foundation

/// Bitstreams that delimit NAL units with start codes instead of length
/// prefixes.
///
/// Every source the engine had before disc images was length-prefixed: MP4
/// and Matroska direct play, and Jellyfin's fMP4 remux and transcode alike.
/// A Blu-ray's m2ts is MPEG-TS, which is not, so reading a disc introduced
/// the engine's first Annex-B source.
///
/// Two consequences, and both are fatal on their own. libavformat synthesises
/// extradata for MPEG-TS out of the in-band parameter sets and hands it over
/// still in Annex-B, so a format description built by treating it as an
/// `hvcC` describes nothing a decoder can use: `VTDecompressionSessionCreate`
/// refuses it, which reads as "no hardware decoder" and is really a framing
/// mismatch. And VideoToolbox cannot decode samples carrying start codes
/// whatever the description says.
nonisolated enum AnnexBStream {
    /// What replaces each start code. Four bytes because a 4K frame's slice
    /// NAL comfortably exceeds what three can address.
    static let nalUnitHeaderLength: Int32 = 4

    /// The two codecs that arrive this way, which read their NAL type out of
    /// different bits of the same header byte.
    enum Codec {
        case hevc
        case h264

        /// Parameter sets in the order a decoder expects to be handed them.
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

    /// Whether these bytes are start-code delimited.
    ///
    /// Asked of a container's extradata, where the alternative is an `hvcC`
    /// or `avcC` record. Neither can begin with a start code: both open with
    /// a configuration version byte of 1.
    static func usesStartCodes(_ data: Data) -> Bool {
        let base = data.startIndex
        guard data.count >= 4 else { return false }
        if data[base] == 0, data[base + 1] == 0, data[base + 2] == 1 { return true }
        return data[base] == 0
            && data[base + 1] == 0
            && data[base + 2] == 0
            && data[base + 3] == 1
    }

    /// The NAL units in a payload, as ranges that exclude their start codes.
    ///
    /// Emulation prevention needs no special handling here: the three-byte
    /// sequence a start code begins with cannot appear inside a NAL, which is
    /// the entire purpose of the escaping.
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

    /// The same NAL units, each prefixed with its length, which is the only
    /// framing VideoToolbox accepts.
    ///
    /// nil when the payload holds no NAL units at all, so a caller can tell
    /// "nothing to convert" from "converted to nothing".
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

    /// The parameter sets a format description has to be built from, in
    /// decoder order.
    ///
    /// nil unless every one of them is present: a description missing any is
    /// the failure this exists to prevent, and falling back to the container's
    /// record leaves the ladder to do its job.
    static func parameterSets(inAnnexB data: Data, codec: Codec) -> [Data]? {
        var found: [UInt8: Data] = [:]
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for unit in nalUnits(in: bytes) where unit.count > 1 {
                let type = codec.nalType(bytes[unit.lowerBound])
                guard codec.parameterSetTypes.contains(type), found[type] == nil else { continue }
                // Trailing zero bytes are legal after a parameter set and
                // routinely present in a stream, but they are padding rather
                // than payload and every muxer trims them before handing the
                // set to a decoder.
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
