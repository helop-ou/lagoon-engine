import Foundation

/// Walks a length-prefixed HEVC access unit, NAL by NAL, applying a per-unit
/// transform.
///
/// P7 remuxes interleave the Dolby Vision enhancement layer and RPU into the
/// base layer's track as unspecified types 63 and 62, which tvOS cannot use —
/// it reconstructs no dual-layer DoVi. `DolbyVisionProfileConverter` rewrites
/// every RPU to profile 8.1 with libdovi; `strippingEnhancementLayer` drops
/// both types wholesale and is the debug fallback that plays the base layer as
/// HDR10.
nonisolated enum HEVCNALUnitRewriter {
    /// What `rewrite` does with one NAL unit.
    enum Action {
        case keep
        case drop
        /// Writes `Data` in the unit's place with a fresh length prefix.
        /// Treated as `.drop` when the replacement doesn't fit the prefix
        /// width it was given.
        case replace(Data)
    }

    /// NAL length-prefix size from the hvcC box (lengthSizeMinusOne, byte
    /// 21) — mp4-style payloads prefix every NAL with this many bytes.
    static func nalLengthSize(hvcc: Data) -> Int? {
        guard hvcc.count > 22 else { return nil }
        return Int(hvcc[hvcc.startIndex + 21] & 0x3) + 1
    }

    /// Walks length-prefixed NAL units, handing each one (header byte
    /// first, no length prefix) to `transform` and rebuilding the payload
    /// from the result.
    ///
    /// Returns nil when nothing was dropped or replaced — so the zero-copy
    /// packet path stays in use — and nil when the payload doesn't parse as
    /// length-prefixed units, so a malformed packet passes through
    /// untouched rather than mangled. Kept byte ranges are coalesced so
    /// consecutive surviving NALs copy in one memmove, same as the original
    /// strip-only implementation.
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
                // Doesn't fit the prefix width: dropped, same as `.drop`.
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

    /// The payload with unspec-62/63 NALs removed — the strip
    /// experiment, now Settings → Advanced → Playback Diagnostics → "Dolby
    /// Vision Compatibility Mode"'s HDR10 fallback for profile 7.
    static func strippingEnhancementLayer(
        from payload: UnsafeRawBufferPointer,
        lengthSize: Int
    ) -> Data? {
        rewrite(payload: payload, lengthSize: lengthSize) { nalType, _ in
            nalType == 62 || nalType == 63 ? .drop : .keep
        }
    }

    /// `unit`, big-endian length-prefixed with `lengthSize` bytes, or nil
    /// when its byte count can't be expressed in that width.
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
