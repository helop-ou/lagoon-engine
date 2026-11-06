import Foundation
import Testing
@testable import LagoonEngine

/// `DolbyVisionRPUChecksum` against dovi_tool's MEL and FEL fixture RPUs,
/// which carry emulation prevention bytes, so the unescape is exercised too.
@Suite("Dolby Vision RPU checksum")
struct DolbyVisionRPUChecksumTests {
    @Test(arguments: DolbyVisionProfileConverterTests.fixtures)
    func aFixtureRPUIsIntact(_ fixture: DolbyVisionProfileConverterTests.RPUFixture) throws {
        let unit = try nal62(fixture)
        #expect(unit.withUnsafeBytes { DolbyVisionRPUChecksum.isIntact(unit: $0) })
        let padded = unit + Data([0x00, 0x00])
        #expect(padded.withUnsafeBytes { DolbyVisionRPUChecksum.isIntact(unit: $0) })
    }

    @Test(arguments: DolbyVisionProfileConverterTests.fixtures)
    func everySingleBitFlipIsRefused(_ fixture: DolbyVisionProfileConverterTests.RPUFixture) throws {
        let unit = try nal62(fixture)
        var accepted: [Int] = []
        for bit in (3 * 8)..<(unit.count * 8) {
            var flipped = unit
            flipped[bit / 8] ^= UInt8(0x80 >> (bit % 8))
            if flipped.withUnsafeBytes({ DolbyVisionRPUChecksum.isIntact(unit: $0) }) {
                accepted.append(bit)
            }
        }
        #expect(accepted.isEmpty)
    }

    @Test func aTruncatedRPUIsRefused() throws {
        let unit = try nal62(DolbyVisionProfileConverterTests.fixtures[0])
        for length in [0, 2, 8, unit.count / 2, unit.count - 1] {
            let truncated = unit.prefix(length)
            #expect(!truncated.withUnsafeBytes { DolbyVisionRPUChecksum.isIntact(unit: $0) })
        }
    }

    /// The fixture as a packet carries it: 0x7C 0x01 header, then the
    /// escaped RPU in place of the start code.
    private func nal62(_ fixture: DolbyVisionProfileConverterTests.RPUFixture) throws -> Data {
        let shipped = try #require(Data(base64Encoded: fixture.originalBase64))
        return Data([0x7C, 0x01]) + shipped.dropFirst(4)
    }
}
