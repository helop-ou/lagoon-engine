import Foundation

/// Whether a length-prefixed access unit can *start* a decoder, which is
/// stricter than the container's keyframe flag.
///
/// In open-GOP H.264, Matroska flags every recovery-point I picture as a key,
/// and none is an IDR. libavcodec starts on one; `AVSampleBufferVideoRenderer`
/// fails to decode it after `flush()`, which the ladder reads as
/// `.undecodable` and transcodes. So the engine asks this, not the flag.
nonisolated enum VideoRandomAccessPoint {
    /// Codecs that reach the renderer compressed.
    enum Codec {
        case h264
        case hevc

        func nalType(_ header: UInt8) -> UInt8 {
            switch self {
            case .h264: header & 0x1F
            case .hevc: (header >> 1) & 0x3F
            }
        }

        /// NAL types that begin a decodable sequence on their own.
        ///
        /// H.264: IDR (5) only. A recovery-point I picture is a gradual
        /// refresh, which a fresh hardware session will not accept.
        /// HEVC: BLA (16-18) through CRA (21). VideoToolbox accepts a CRA;
        /// 22 and 23 are reserved.
        var randomAccessTypes: ClosedRange<UInt8> {
            switch self {
            case .h264: 5...5
            case .hevc: 16...21
            }
        }

        /// Parameter sets. Traced, because their absence also fails a first
        /// post-flush sample.
        var parameterSetTypes: Set<UInt8> {
            switch self {
            case .h264: [7, 8]
            case .hevc: [32, 33, 34]
            }
        }

        /// Byte holding `lengthSizeMinusOne` in the `avcC`/`hvcC` record.
        var nalLengthSizeByte: Int {
            switch self {
            case .h264: 4
            case .hevc: 21
            }
        }
    }

    /// NAL length prefix width from an `avcC`/`hvcC` record; nil (do not
    /// filter) when the record is too short.
    static func nalLengthSize(configurationRecord record: Data, codec: Codec) -> Int? {
        let index = record.startIndex + codec.nalLengthSizeByte
        guard record.count > codec.nalLengthSizeByte else { return nil }
        return Int(record[index] & 0x3) + 1
    }

    /// Every NAL type in one access unit, in order. nil when the payload does
    /// not parse, so a malformed packet is left alone, not misclassified.
    static func nalTypes(
        lengthPrefixed payload: UnsafeRawBufferPointer,
        lengthSize: Int,
        codec: Codec
    ) -> [UInt8]? {
        guard payload.baseAddress != nil, (1...4).contains(lengthSize) else { return nil }
        let count = payload.count
        var types: [UInt8] = []
        var offset = 0
        while offset < count {
            guard offset + lengthSize <= count else { return nil }
            var nalLength = 0
            for index in 0..<lengthSize {
                nalLength = nalLength << 8 | Int(payload[offset + index])
            }
            let start = offset + lengthSize
            let end = start + nalLength
            guard nalLength > 0, end <= count else { return nil }
            types.append(codec.nalType(payload[start]))
            offset = end
        }
        return types.isEmpty ? nil : types
    }

    /// Whether these NAL types can start a decoder.
    static func isDecoderStartPoint(nalTypes: [UInt8], codec: Codec) -> Bool {
        nalTypes.contains { codec.randomAccessTypes.contains($0) }
    }

    /// The same question asked of a payload. nil means "cannot tell", which
    /// every caller treats as "let it through".
    static func isDecoderStartPoint(
        lengthPrefixed payload: UnsafeRawBufferPointer,
        lengthSize: Int,
        codec: Codec
    ) -> Bool? {
        guard let types = nalTypes(lengthPrefixed: payload, lengthSize: lengthSize, codec: codec) else {
            return nil
        }
        return isDecoderStartPoint(nalTypes: types, codec: codec)
    }

    /// A compact `5,1,8` rendering for the decode trace.
    static func traceDescription(nalTypes: [UInt8]) -> String {
        nalTypes.map(String.init).joined(separator: ",")
    }
}
