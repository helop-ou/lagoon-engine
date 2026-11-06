import Foundation

/// Checks a Dolby Vision RPU's CRC32 before libdovi sees it.
///
/// libdovi 3.4 parses the whole RPU before it compares the CRC, and a
/// corrupt one can reach an `unimplemented!()` in its mapping parser. The
/// library is built panic=abort, so that ends the process. A corrupt RPU is
/// refused here instead and dropped like any other that fails to parse. The
/// measurement is in the queues and renderers notes.
nonisolated enum DolbyVisionRPUChecksum {
    /// CRC-32/MPEG-2, as libdovi's `compute_crc32`.
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index) << 24
        for _ in 0..<8 {
            crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
        }
        return crc
    }

    /// Whether `unit`, a type-62 NAL from its 2-byte header with emulation
    /// prevention in place, carries the CRC32 its payload hashes to. Laid out
    /// unescaped: header, 0x19, payload, CRC32, 0x80, any trailing zeros.
    static func isIntact(unit: UnsafeRawBufferPointer) -> Bool {
        var bytes = [UInt8]()
        bytes.reserveCapacity(unit.count)
        var zeros = 0
        for byte in unit {
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            bytes.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        while bytes.last == 0 {
            bytes.removeLast()
        }
        guard bytes.count >= 2 + 7, bytes[2] == 0x19, bytes[bytes.count - 1] == 0x80 else { return false }

        let crcStart = bytes.count - 5
        var crc: UInt32 = 0xFFFF_FFFF
        for index in 3..<crcStart {
            crc = (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(bytes[index]))]
        }
        let stored = bytes[crcStart..<(crcStart + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return crc == stored
    }
}
