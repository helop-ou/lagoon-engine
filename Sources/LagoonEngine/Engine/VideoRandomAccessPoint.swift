import Foundation

/// Whether a length-prefixed access unit is somewhere a decoder can be
/// *started*, as opposed to somewhere a container is willing to seek.
///
/// The two are not the same thing, and the difference ends a direct play.
/// `AV_PKT_FLAG_KEY` on a Matroska block means the muxer marked
/// the block seekable; for an open-GOP H.264 encode that is every
/// recovery-point I picture, none of which is an IDR. libavcodec starts on
/// one happily — it decodes the recovery period and lets the leading
/// pictures come out wrong for a few frames. `AVSampleBufferVideoRenderer`
/// does not: the first sample after `flush()` has to be a real random-access
/// point, and anything else comes back as `didFailToDecodeNotification`,
/// which the delivery ladder reads as `.undecodable` and answers with a
/// server-side transcode.
///
/// So the engine asks this instead of the flag.
nonisolated enum VideoRandomAccessPoint {
    /// The two length-prefixed codecs that reach `AVSampleBufferVideoRenderer`
    /// as compressed samples. They read the NAL type out of different bits
    /// of the same header byte.
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
        /// H.264: only the IDR (5). A `recovery_point` SEI attached to a
        /// non-IDR I picture (1) is a *gradual* refresh — correct output is
        /// promised some frames later, which is exactly the promise a
        /// hardware decoder handed a fresh session will not accept.
        ///
        /// HEVC: the IRAP range, BLA (16-18) through CRA (21). A CRA is a
        /// clean random-access point whose leading RASL pictures the decoder
        /// discards by specification, so VideoToolbox accepts one; 22 and 23
        /// are reserved IRAP types and are not assumed decodable.
        var randomAccessTypes: ClosedRange<UInt8> {
            switch self {
            case .h264: 5...5
            case .hevc: 16...21
            }
        }

        /// Sequence/picture parameter sets, worth naming in a trace because
        /// their absence is the other way a first post-flush sample fails.
        var parameterSetTypes: Set<UInt8> {
            switch self {
            case .h264: [7, 8]
            case .hevc: [32, 33, 34]
            }
        }

        /// The codec's configuration record byte holding `lengthSizeMinusOne`
        /// — `avcC` puts it at 4, `hvcC` at 21.
        var nalLengthSizeByte: Int {
            switch self {
            case .h264: 4
            case .hevc: 21
            }
        }
    }

    /// NAL length prefix width from an `avcC`/`hvcC` record.
    ///
    /// nil when the record is too short to carry the field, which is the
    /// same "we cannot tell" the callers treat as "do not filter".
    static func nalLengthSize(configurationRecord record: Data, codec: Codec) -> Int? {
        let index = record.startIndex + codec.nalLengthSizeByte
        guard record.count > codec.nalLengthSizeByte else { return nil }
        return Int(record[index] & 0x3) + 1
    }

    /// Every NAL type in one length-prefixed access unit, in order.
    ///
    /// nil when the payload does not parse as length-prefixed units — a
    /// malformed or differently framed packet must not be *classified*, so
    /// callers can leave it alone rather than act on a wrong reading.
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

    /// The same question asked of a payload, for callers that hold bytes.
    ///
    /// nil means "cannot tell" — an unparseable payload, an unknown length
    /// size — and every caller treats that as "let it through", so a stream
    /// this cannot read behaves exactly as it did before this existed.
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
