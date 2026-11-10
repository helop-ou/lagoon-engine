import Foundation

/// Finds ATSC A/53 closed captions in a video access unit: the `GA94`
/// `cc_data` that H.264 and HEVC carry in a registered user-data SEI and
/// MPEG-2 carries in picture user data. Returns the `cc_data` triplets
/// (marker and type, then two bytes), the form FFmpeg's `ccaption` decoder
/// reads.
///
/// The walk stops at the first slice: the SEI and user data come before it,
/// and the slices are most of an access unit's bytes.
nonisolated enum ClosedCaptionExtractor {
    enum Codec {
        case h264
        case hevc
        case mpeg2
    }

    /// `payload` is length-prefixed when `nalLengthSize` is given, else
    /// start-code delimited. MPEG-2 is always start-code delimited.
    static func captions(in payload: UnsafeRawBufferPointer, codec: Codec, nalLengthSize: Int?) -> Data {
        var captions = Data()
        let visit: (UnsafeRawBufferPointer) -> Void = { unit in
            switch codec {
            case .h264:
                if unit[0] & 0x1F == 6 { captions.append(seiCaptions(rbsp(unit, dropping: 1))) }
            case .hevc:
                if (unit[0] >> 1) & 0x3F == 39, unit.count > 2 { captions.append(seiCaptions(rbsp(unit, dropping: 2))) }
            case .mpeg2:
                if unit[0] == 0xB2 { captions.append(userDataCaptions(Data(unit.dropFirst(1)))) }
            }
        }
        if codec == .mpeg2 || nalLengthSize == nil {
            walkStartCodeUnits(payload, isSlice: { isSlice($0, codec) }, visit: visit)
        } else {
            walkLengthPrefixedUnits(payload, lengthSize: nalLengthSize!, isSlice: { isSlice($0, codec) }, visit: visit)
        }
        return captions
    }

    private static func isSlice(_ firstByte: UInt8, _ codec: Codec) -> Bool {
        switch codec {
        case .h264: (1...5).contains(firstByte & 0x1F)
        case .hevc: (firstByte >> 1) & 0x3F < 32
        case .mpeg2: (0x01...0xAF).contains(firstByte)
        }
    }

    /// SEI messages, each a type and a size coded in 0xFF runs, until the
    /// trailing bits.
    static func seiCaptions(_ rbsp: Data) -> Data {
        var captions = Data()
        var index = rbsp.startIndex
        func coded() -> Int? {
            var value = 0
            while index < rbsp.endIndex {
                let byte = rbsp[index]
                index += 1
                value += Int(byte)
                if byte != 0xFF { return value }
            }
            return nil
        }
        while index < rbsp.endIndex, rbsp[index] != 0x80 {
            guard let type = coded(), let size = coded(), index + size <= rbsp.endIndex else { break }
            let message = rbsp[index..<(index + size)]
            index += size
            // user_data_registered_itu_t_t35: United States, ATSC.
            if type == 4, message.count > 3, message.first == 0xB5,
               message[message.startIndex + 1] == 0x00, message[message.startIndex + 2] == 0x31 {
                captions.append(userDataCaptions(Data(message.dropFirst(3))))
            }
        }
        return captions
    }

    /// `GA94`, user_data_type_code 3, then `cc_data` with its process flag.
    static func userDataCaptions(_ data: Data) -> Data {
        let bytes = Array(data)
        guard bytes.count >= 7, bytes[0...3] == [0x47, 0x41, 0x39, 0x34], bytes[4] == 0x03,
              bytes[5] & 0x40 != 0 else { return Data() }
        let count = Int(bytes[5] & 0x1F)
        guard 7 + count * 3 <= bytes.count else { return Data() }
        return Data(bytes[7..<(7 + count * 3)])
    }

    /// The unit past its header, without emulation prevention bytes.
    static func rbsp(_ unit: UnsafeRawBufferPointer, dropping header: Int) -> Data {
        var out = Data(capacity: unit.count)
        var zeros = 0
        for byte in unit.dropFirst(header) {
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    private static func walkLengthPrefixedUnits(
        _ payload: UnsafeRawBufferPointer,
        lengthSize: Int,
        isSlice: (UInt8) -> Bool,
        visit: (UnsafeRawBufferPointer) -> Void
    ) {
        guard (1...4).contains(lengthSize) else { return }
        var offset = 0
        while offset + lengthSize < payload.count {
            var length = 0
            for index in 0..<lengthSize {
                length = length << 8 | Int(payload[offset + index])
            }
            let start = offset + lengthSize
            guard length > 0, start + length <= payload.count, !isSlice(payload[start]) else { return }
            visit(UnsafeRawBufferPointer(rebasing: payload[start..<(start + length)]))
            offset = start + length
        }
    }

    /// Each unit after a 00 00 01, up to the next start code. A slice is
    /// recognised from its first byte, before its end is searched for.
    private static func walkStartCodeUnits(
        _ payload: UnsafeRawBufferPointer,
        isSlice: (UInt8) -> Bool,
        visit: (UnsafeRawBufferPointer) -> Void
    ) {
        var start = nextStartCode(payload, from: 0)
        while let unitStart = start, unitStart < payload.count {
            guard !isSlice(payload[unitStart]) else { return }
            let next = nextStartCode(payload, from: unitStart)
            var end = next.map { $0 - 3 } ?? payload.count
            // A four-byte start code leaves its leading zero on the unit before.
            while end > unitStart, payload[end - 1] == 0 { end -= 1 }
            if end > unitStart {
                visit(UnsafeRawBufferPointer(rebasing: payload[unitStart..<end]))
            }
            start = next
        }
    }

    /// The offset just past the next 00 00 01 at or after `from`.
    private static func nextStartCode(_ payload: UnsafeRawBufferPointer, from: Int) -> Int? {
        var index = from
        while index + 2 < payload.count {
            if payload[index + 2] > 1 {
                index += 3
            } else if payload[index] == 0, payload[index + 1] == 0, payload[index + 2] == 1 {
                return index + 3
            } else {
                index += 1
            }
        }
        return nil
    }
}
