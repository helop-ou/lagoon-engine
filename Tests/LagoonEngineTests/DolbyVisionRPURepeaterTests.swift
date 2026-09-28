import Foundation
import Testing
@testable import LagoonEngine

/// Native profile 5 and 8: a frame without an RPU gets the previous frame's,
/// because VideoToolbox refuses a Dolby Vision frame without one.
@Suite("Dolby Vision RPU repeat")
struct DolbyVisionRPURepeaterTests {
    private let vcl = Data([0x02, 0x01]) + Data(repeating: 0xAB, count: 40)
    private let nextVCL = Data([0x02, 0x01]) + Data(repeating: 0xCD, count: 40)
    private let rpu = Data([0x7C, 0x01]) + Data(repeating: 0x5A, count: 24)

    @Test func aFrameWithItsOwnRPUPassesThroughZeroCopy() {
        let repeater = DolbyVisionRPURepeater()
        let packet = lengthPrefixed([vcl, rpu])
        #expect(packet.withUnsafeBytes { repeater.fill(payload: $0, lengthSize: 4) } == nil)
        #expect(repeater.repeatedCount == 0)
    }

    @Test func aFrameWithoutOneGetsThePreviousRPUAtTheEnd() throws {
        let repeater = DolbyVisionRPURepeater()
        _ = lengthPrefixed([vcl, rpu]).withUnsafeBytes { repeater.fill(payload: $0, lengthSize: 4) }
        let filled = try #require(lengthPrefixed([nextVCL]).withUnsafeBytes { repeater.fill(payload: $0, lengthSize: 4) })
        #expect(filled == lengthPrefixed([nextVCL, rpu]))
        #expect(repeater.repeatedCount == 1)
    }

    @Test func nothingIsRepeatedBeforeTheFirstRPU() {
        let repeater = DolbyVisionRPURepeater()
        #expect(lengthPrefixed([vcl]).withUnsafeBytes { repeater.fill(payload: $0, lengthSize: 4) } == nil)
        #expect(repeater.repeatedCount == 0)
    }

    @Test func aMalformedFrameIsLeftAlone() {
        let repeater = DolbyVisionRPURepeater()
        _ = lengthPrefixed([vcl, rpu]).withUnsafeBytes { repeater.fill(payload: $0, lengthSize: 4) }
        let overrun = Data([0x00, 0x00, 0x01, 0x00]) + vcl
        #expect(overrun.withUnsafeBytes { repeater.fill(payload: $0, lengthSize: 4) } == nil)
        #expect(repeater.repeatedCount == 0)
    }

    @Test func onlyProfilesFiveAndEightRepeat() {
        #expect(DolbyVisionRPURepeater.applies(toProfile: 5))
        #expect(DolbyVisionRPURepeater.applies(toProfile: 8))
        // 7 has the converter; 10 is AV1, whose metadata is not a NAL unit.
        for profile: UInt8 in [4, 7, 9, 10] {
            #expect(!DolbyVisionRPURepeater.applies(toProfile: profile))
        }
    }

    @Test func theFirstUnitOfATypeIsFoundWithoutCopying() throws {
        let packet = lengthPrefixed([vcl, rpu, nextVCL])
        let found = try #require(packet.withUnsafeBytes {
            HEVCNALUnitRewriter.firstUnit(ofType: 62, in: $0, lengthSize: 4).map { Data($0) }
        })
        #expect(found == rpu)
        #expect(lengthPrefixed([vcl]).withUnsafeBytes {
            HEVCNALUnitRewriter.firstUnit(ofType: 62, in: $0, lengthSize: 4)
        } == nil)
    }

    private func lengthPrefixed(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units {
            for shift in stride(from: 24, through: 0, by: -8) {
                result.append(UInt8((unit.count >> shift) & 0xFF))
            }
            result.append(unit)
        }
        return result
    }
}
