import Dovi
import Foundation
import Libavutil
import Testing
@testable import LagoonEngine

/// The profile 7 → 8.1 RPU rewrite: `DolbyVisionProfileConverter` rewrites
/// every RPU (unspec-62) NAL with libdovi's
/// `dovi_convert_rpu_with_mode(rpu, 2)` and drops the enhancement layer
/// (unspec-63), using `HEVCNALUnitRewriter.rewrite` to walk packets.
///
/// Fixtures are dovi_tool's own MEL/FEL pairs from `assets/tests` at
/// libdovi-3.4.0: `*_orig` are real profile 7 RPUs, `*_to_81` what its
/// `mel_conversions`/`fel_conversions` tests expect. The first two tests
/// exercise no Lagoon code — they confirm the vendored library converts the
/// way dovi_tool's tests say before anything here trusts it.
///
/// Each constant is the file as shipped: a 4-byte Annex B start code then one
/// *escaped* RPU (first byte 0x19, no 0x7C 0x01 NAL header), hence
/// `dovi_parse_unspec62_nalu` rather than `dovi_parse_rpu`.
@Suite("Dolby Vision profile 7 conversion")
struct DolbyVisionProfileConverterTests {
    /// `DoviRpuOpaque *` is an opaque, forward-declared C struct with no
    /// visible fields, so the ClangImporter has nothing to bridge but the
    /// pointer itself, as `OpaquePointer` — the same pattern as
    /// `resampler: OpaquePointer?` for `SwrContext *` in AudioDecoder.swift.
    /// This alias just keeps call sites readable.
    private typealias DoviRpuOpaque = OpaquePointer

    // MARK: - Fixtures (dovi_tool's own test suite, libdovi 3.4.0 tag)

    private static let melOriginalBase64 = """
    AAAAARkICQhAYTZQrwA/+AH/wA/8AB//oAAAEAAADQAAAwCAAABoAAAEAAADAABAAAAgAAAgAAADAAQAAAMCAAADAgAAAwAAQAAA
    IAAAIAAANErMAABr1ErN8/nWOErMiZQAAAMCAAADABAAAAMAEAAAAwA4bESGAwwUvGEcCigAAAMDTHy1//4AAAMAAAMAAAMAAMBA
    HwHCogAwCABPkw8BARXwrkSDAfQAAIAAAAMAAPkfd+6A
    """.filter { !$0.isWhitespace }

    private static let melTo81Base64 = """
    AAAAARkICQhAYTZQbwA/+AH/wA//0AAACAAABoAAAEAAADQAAAMCAAADAaJWYAADXqJWb5/OscJWZEygAAAQAAADAIAAAAMAgAAA
    AwHDYiQwGGCl4wjgUUAAABpj5a//8AAAAwAAAwAAAwAGAgD4DhUQMAgAT5MPAQEV8K5EgwH0AACAAAADAACM9CDVgA==
    """.filter { !$0.isWhitespace }

    private static let felOriginalBase64 = """
    AAAAARkICQhAYTZQriAAIAgCAIAgCAIAf4Af/AD/wAH/+gAAAwEAAAMA0AAACAAABoAAAEAAADQAAAMCAAADAaAAABAAAA0AAAMA
    gAAAaAAABAAAAwNAAAAgAAAKhtnmey+GPvwYnmAp6YwGuMVmp81fjf/LbYw544qZgbhspnkPQF9DTLfYDp4Ew0n9O7d+ws1d46FH
    1EwKLoBiFkoCm11ZUA7Tj1jEbE7BOhRYLP8wI1NtV7u25BFIO5KWZBNpj85rwxvWIPrdQFu+9GQxYLHwG/Lu+/Kl4vPMtKvzzDmD
    d551aDEbAEgAAEAEAEAAAEASAAAQAQAQAAAQBIAABABABAAAByVmAAA16iVm+fzrHCVmRMoAAAMBAAADAAgAAAMACAAAAwAcNiJD
    AYYKXjCOBRQAAAMBpj5a//8AAAMAAAMAAAMAAGAgD4DhUYAwCABZyhIAwCghjfglgAgAYUAAAgIqUSCIBQAAAwACKBFQEgwH0AAC
    DWABXrjynYKA
    """.filter { !$0.isWhitespace }

    private static let felTo81Base64 = """
    AAAAARkICQhAYTZQbiAAIAgCAIAgCAIAf4Af/AD//QAAAwCAAABoAAAEAAADA0AAACAAABoAAAMBAAADANAAAAgAAAaAAABAAAA0
    AAADAgAAAwGgAAAQAAAFQ2zzPZfDH34MTzAU9MYDXGKzU+avxv/ltsYc8cVMwNw2UzyHoC+hplvsB08CYaT+ndu/YWau8dCj6iYF
    F0AxCyUBTa6sqAdpx6xiNidgnQosFn+YEam2q93bcgikHclLMgm0x+c14Y3rEH1uoC3fejIYsFj4Dfl3fflS8XnmWlX55hzBu886
    tBiN5KzAAAa9RKzfP51jhKzImUAAACAAAAMBAAADAAEAAAMAA4bESGAwwUvGEcCigAAANMfLX//gAAADAAADAAADAAwEAfAcKjAw
    CABZyhIAwCghjfglgAgAYUAAAgIqUSCIBQAAAwACKBFQEgwH0AACDWABXmIQxo2A
    """.filter { !$0.isWhitespace }

    struct RPUFixture: Sendable {
        /// "MEL" or "FEL" — also the enhancement-layer type libdovi reports
        /// off the parsed header, and what the converter's stats should say.
        let label: String
        let originalBase64: String
        let convertedBase64: String
        /// Whether one direct mode-2 call — what the converter ships —
        /// reproduces `convertedBase64`. True for MEL. False for FEL: mode 2
        /// on a FEL source also resets the base-layer mapping curves to the
        /// identity polynomial, which upstream's MEL-first reference path
        /// never does.
        let directMode2MatchesFixture: Bool
    }

    nonisolated static let fixtures: [RPUFixture] = [
        RPUFixture(
            label: "MEL",
            originalBase64: melOriginalBase64,
            convertedBase64: melTo81Base64,
            directMode2MatchesFixture: true
        ),
        RPUFixture(
            label: "FEL",
            originalBase64: felOriginalBase64,
            convertedBase64: felTo81Base64,
            directMode2MatchesFixture: false
        ),
    ]

    // MARK: - Fixture / libdovi helpers

    /// Decodes a fixture constant as shipped: start code plus escaped RPU.
    private func decodeFixture(_ base64: String) throws -> Data {
        try #require(Data(base64Encoded: base64))
    }

    /// Parses a fixture, or a written NAL, the way dovi_tool's `_parse_file`
    /// does: `parse_unspec62_nalu` trims a leading start code or 0x7C 0x01
    /// header itself and clears emulation prevention before decoding.
    private func parseNAL(_ data: Data) -> DoviRpuOpaque? {
        data.withUnsafeBytes { buffer -> DoviRpuOpaque? in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return dovi_parse_unspec62_nalu(base, buffer.count)
        }
    }

    /// `DoviData.data` is an implicitly-unwrapped optional pointer; unwrap
    /// it explicitly with `guard let` (as the rest of the codebase's
    /// FFmpeg/DoVi bridging does, e.g. `codecpar.pointee.extradata` in
    /// FFmpegDemuxer.swift) rather than lean on a force-unwrap-plus-
    /// typed-to-raw-pointer conversion happening together at a call site.
    private func bytes(from doviData: DoviData) -> Data {
        guard let base = doviData.data else { return Data() }
        return Data(bytes: base, count: doviData.len)
    }

    /// The escaped, 0x7C 0x01-prefixed NAL unit a real packet carries for
    /// an *unconverted* RPU — this is how the tests below build the type-62
    /// unit that goes into a synthetic access unit.
    private func nal62(from fixture: Data) throws -> Data {
        let rpu = try #require(parseNAL(fixture))
        defer { dovi_rpu_free(rpu) }
        let written = try #require(dovi_write_unspec62_nalu(rpu))
        defer { dovi_data_free(written) }
        return bytes(from: written.pointee)
    }

    /// The same, but mode-2 converted first — what the converter under test
    /// should be producing in place of the original RPU unit.
    private func convertedNal62(from fixture: Data) throws -> Data {
        let rpu = try #require(parseNAL(fixture))
        defer { dovi_rpu_free(rpu) }
        #expect(dovi_convert_rpu_with_mode(rpu, 2) == 0)
        let written = try #require(dovi_write_unspec62_nalu(rpu))
        defer { dovi_data_free(written) }
        return bytes(from: written.pointee)
    }

    // MARK: - Access-unit helpers

    private func lengthPrefixed(units: [Data], lengthSize: Int) -> Data {
        var result = Data()
        for unit in units {
            for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
                result.append(UInt8((unit.count >> shift) & 0xFF))
            }
            result.append(unit)
        }
        return result
    }

    private func parseLengthPrefixedUnits(_ data: Data, lengthSize: Int) -> [Data] {
        var units: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            var length = 0
            for _ in 0..<lengthSize {
                length = (length << 8) | Int(data[offset])
                offset += 1
            }
            let unitEnd = data.index(offset, offsetBy: length)
            units.append(data[offset..<unitEnd])
            offset = unitEnd
        }
        return units
    }

    /// A profile 7, dual-layer (FEL/MEL) decoder configuration record —
    /// dv_version 1.0, level 6, compatibility id 6 (the "backward
    /// compatible with neither BL nor EL alone" id real P7 remuxes use).
    private func profileSevenRecord() -> AVDOVIDecoderConfigurationRecord {
        AVDOVIDecoderConfigurationRecord(
            dv_version_major: 1,
            dv_version_minor: 0,
            dv_profile: 7,
            dv_level: 6,
            rpu_present_flag: 1,
            el_present_flag: 1,
            bl_present_flag: 1,
            dv_bl_signal_compatibility_id: 6,
            dv_md_compression: 0
        )
    }

    // MARK: - libdovi itself, against dovi_tool's own reference output

    /// Byte for byte what dovi_tool's `fel_conversions`/`mel_conversions`
    /// assert: parse, convert to MEL (mode 1), convert to 8.1 (mode 2), and
    /// the written NAL minus its 0x7C 0x01 header equals the shipped
    /// `_to_81` fixture minus its start code.
    @Test(arguments: fixtures)
    func vendoredLibdoviMatchesDoviToolsReferenceOutput(_ fixture: RPUFixture) throws {
        let expected = try decodeFixture(fixture.convertedBase64)
        let rpu = try #require(parseNAL(try decodeFixture(fixture.originalBase64)))
        defer { dovi_rpu_free(rpu) }
        #expect(dovi_rpu_get_error(rpu) == nil)

        #expect(dovi_convert_rpu_with_mode(rpu, 1) == 0)
        #expect(dovi_convert_rpu_with_mode(rpu, 2) == 0)
        #expect(dovi_rpu_get_error(rpu) == nil)

        let written = try #require(dovi_write_unspec62_nalu(rpu))
        defer { dovi_data_free(written) }
        #expect(bytes(from: written.pointee).dropFirst(2) == expected.dropFirst(4))
    }

    /// What the converter ships is one direct mode-2 call. For MEL that is
    /// identical to the reference above. For FEL, libdovi 3.x's mode 2 also
    /// resets the base layer's luma and chroma mapping curves to the
    /// identity polynomial (a FEL mapping was designed to be applied with
    /// the residual; mode 4 is the old mapping-preserving behaviour), so the
    /// RPU shrinks — and must still read back as profile 8.
    @Test(arguments: fixtures)
    func directMode2ReadsBackAsProfile8(_ fixture: RPUFixture) throws {
        let expected = try decodeFixture(fixture.convertedBase64)
        let rpu = try #require(parseNAL(try decodeFixture(fixture.originalBase64)))
        defer { dovi_rpu_free(rpu) }
        #expect(dovi_convert_rpu_with_mode(rpu, 2) == 0)
        #expect(dovi_rpu_get_error(rpu) == nil)

        let written = try #require(dovi_write_unspec62_nalu(rpu))
        defer { dovi_data_free(written) }
        let nal = bytes(from: written.pointee)

        let reparsed = try #require(parseNAL(nal))
        defer { dovi_rpu_free(reparsed) }
        #expect(dovi_rpu_get_error(reparsed) == nil)
        let header = try #require(dovi_rpu_get_header(reparsed))
        defer { dovi_rpu_free_header(header) }
        #expect(header.pointee.guessed_profile == 8)

        if fixture.directMode2MatchesFixture {
            #expect(nal.dropFirst(2) == expected.dropFirst(4))
        } else {
            #expect(nal.count - 2 < expected.count - 4, "identity mapping curves make the FEL RPU smaller than the mapping-preserving reference")
        }
    }

    // MARK: - DolbyVisionProfileConverter

    @Test(arguments: fixtures)
    func aPacketsRPUIsRewrittenAndItsEnhancementLayerDropped(_ fixture: RPUFixture) throws {
        let original = try decodeFixture(fixture.originalBase64)

        let vclUnit = Data([0x02, 0x01]) + Data(repeating: 0xAB, count: 40)
        let rpu62 = try nal62(from: original)
        let el63 = Data([0x7E, 0x01]) + Data(repeating: 0xEF, count: 64)
        let packet = lengthPrefixed(units: [vclUnit, rpu62, el63], lengthSize: 4)

        let converter = try #require(DolbyVisionProfileConverter(record: profileSevenRecord()))
        let result = try #require(packet.withUnsafeBytes { converter.convert(payload: $0, lengthSize: 4) })

        let units = parseLengthPrefixedUnits(result, lengthSize: 4)
        #expect(units.count == 2)
        #expect(units.first == vclUnit)

        let expectedRPU62 = try convertedNal62(from: original)
        #expect(units.last == expectedRPU62)

        let stats = converter.stats
        #expect(stats.packets == 1)
        #expect(stats.rpusConverted == 1)
        #expect(stats.rpusDropped == 0)
        #expect(stats.enhancementUnitsDropped == 1)
        #expect(stats.errors == 0)
        #expect(stats.bytesRemoved == Int64(packet.count - result.count))
        #expect(stats.enhancementLayerType == fixture.label)
    }

    @Test func aPacketWithoutDolbyVisionUnitsKeepsTheZeroCopyPath() throws {
        let vclUnit = Data([0x02, 0x01]) + Data(repeating: 0xAB, count: 40)
        let anotherVCLUnit = Data([0x24, 0x01]) + Data(repeating: 0xCD, count: 10)
        let packet = lengthPrefixed(units: [vclUnit, anotherVCLUnit], lengthSize: 4)

        let converter = try #require(DolbyVisionProfileConverter(record: profileSevenRecord()))
        let statsBefore = converter.stats

        let result = packet.withUnsafeBytes { converter.convert(payload: $0, lengthSize: 4) }
        #expect(result == nil)
        // Nothing to rewrite: the packet keeps its zero-copy path, and the
        // stats stay exactly as they were — not just zeroed, untouched.
        #expect(converter.stats == statsBefore)
    }

    @Test func aMalformedRPUIsDroppedAndCounted() throws {
        let vclUnit = Data([0x02, 0x01]) + Data(repeating: 0xAB, count: 40)
        let malformedRPU62 = Data([0x7C, 0x01]) + Data(repeating: 0xFF, count: 20)
        let packet = lengthPrefixed(units: [vclUnit, malformedRPU62], lengthSize: 4)

        let converter = try #require(DolbyVisionProfileConverter(record: profileSevenRecord()))
        let result = try #require(packet.withUnsafeBytes { converter.convert(payload: $0, lengthSize: 4) })

        let units = parseLengthPrefixedUnits(result, lengthSize: 4)
        #expect(units == [vclUnit])

        let stats = converter.stats
        #expect(stats.errors == 1)
        #expect(stats.rpusDropped == 1)
    }

    // MARK: - synthesizedRecord / init?(record:)

    @Test func theSynthesizedRecordDescribesProfile81() throws {
        let converter = try #require(DolbyVisionProfileConverter(record: profileSevenRecord()))
        let synthesized = converter.synthesizedRecord
        #expect(synthesized.dv_profile == 8)
        #expect(synthesized.dv_level == 6)
        #expect(synthesized.dv_version_major == 1)
        #expect(synthesized.dv_version_minor == 0)
        #expect(synthesized.rpu_present_flag == 1)
        #expect(synthesized.el_present_flag == 0)
        #expect(synthesized.bl_present_flag == 1)
        #expect(synthesized.dv_bl_signal_compatibility_id == 1)
        #expect(synthesized.dv_md_compression == 0)
    }

    @Test func onlyProfileSevenGetsAConverter() {
        var notProfileSeven = profileSevenRecord()

        notProfileSeven.dv_profile = 5
        #expect(DolbyVisionProfileConverter(record: notProfileSeven) == nil)

        notProfileSeven.dv_profile = 8
        #expect(DolbyVisionProfileConverter(record: notProfileSeven) == nil)

        #expect(DolbyVisionProfileConverter(record: profileSevenRecord()) != nil)
    }
}
