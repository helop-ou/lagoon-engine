import Foundation

/// Walks a length-prefixed HEVC access unit, applying a per-NAL transform.
///
/// Dolby Vision profile 7 carries its enhancement layer and RPU as NAL types
/// 63 and 62, which tvOS cannot use. `DolbyVisionProfileConverter` rewrites
/// the RPU to profile 8.1; `strippingEnhancementLayer` drops both types and
/// plays the base layer as HDR10.
nonisolated enum HEVCNALUnitRewriter {
    /// What `rewrite` does with one NAL unit.
    enum Action {
        case keep
        case drop
        /// Writes `Data` in the unit's place with a fresh length prefix, or
        /// drops the unit if it does not fit the prefix width.
        case replace(Data)
    }

    /// NAL length-prefix size from the hvcC box (lengthSizeMinusOne, byte 21).
    static func nalLengthSize(hvcc: Data) -> Int? {
        guard hvcc.count > 22 else { return nil }
        return Int(hvcc[hvcc.startIndex + 21] & 0x3) + 1
    }

    /// Hands each NAL unit (without its length prefix) to `transform` and
    /// rebuilds the payload.
    ///
    /// Returns nil when nothing changed, so the zero-copy path stays in use,
    /// and nil when the payload does not parse, so a malformed packet passes
    /// through untouched.
    static func rewrite(
        payload: UnsafeRawBufferPointer,
        lengthSize: Int,
        transform: (_ nalType: UInt8, _ unit: UnsafeRawBufferPointer) -> Action
    ) -> Data? {
        guard let base = payload.baseAddress, (1...4).contains(lengthSize) else { return nil }
        let count = payload.count
        enum Segment {
            case copy(start: Int, end: Int)
            case bytes(Data)
        }
        var segments: [Segment] = []
        var changed = false
        var offset = 0
        while offset < count {
            guard offset + lengthSize <= count else { return nil }
            var nalLength = 0
            for index in 0..<lengthSize {
                nalLength = nalLength << 8 | Int(payload[offset + index])
            }
            let unitStart = offset + lengthSize
            let unitEnd = unitStart + nalLength
            guard nalLength > 0, unitEnd <= count else { return nil }
            let nalType = (payload[unitStart] >> 1) & 0x3F
            let unit = UnsafeRawBufferPointer(start: base.advanced(by: unitStart), count: unitEnd - unitStart)
            switch transform(nalType, unit) {
            case .keep:
                if case .copy(let start, let end) = segments.last, end == offset {
                    segments[segments.count - 1] = .copy(start: start, end: unitEnd)
                } else {
                    segments.append(.copy(start: offset, end: unitEnd))
                }
            case .drop:
                changed = true
            case .replace(let newUnit):
                changed = true
                if let prefixed = lengthPrefixed(newUnit, lengthSize: lengthSize) {
                    segments.append(.bytes(prefixed))
                }
                // Too long for the prefix width: dropped.
            }
            offset = unitEnd
        }
        guard changed else { return nil }
        var result = Data(capacity: count)
        for segment in segments {
            switch segment {
            case .copy(let start, let end):
                result.append(base.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: end - start)
            case .bytes(let data):
                result.append(data)
            }
        }
        return result
    }

    /// The payload with NAL types 62 and 63 removed: the HDR10 fallback for
    /// profile 7.
    static func strippingEnhancementLayer(
        from payload: UnsafeRawBufferPointer,
        lengthSize: Int
    ) -> Data? {
        rewrite(payload: payload, lengthSize: lengthSize) { nalType, _ in
            nalType == 62 || nalType == 63 ? .drop : .keep
        }
    }

    /// `unit` with a big-endian length prefix, or nil if it does not fit.
    private static func lengthPrefixed(_ unit: Data, lengthSize: Int) -> Data? {
        let maxLength = (1 << (8 * lengthSize)) - 1
        guard unit.count <= maxLength else { return nil }
        var result = Data(capacity: lengthSize + unit.count)
        for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
            result.append(UInt8((unit.count >> shift) & 0xFF))
        }
        result.append(unit)
        return result
    }
}
