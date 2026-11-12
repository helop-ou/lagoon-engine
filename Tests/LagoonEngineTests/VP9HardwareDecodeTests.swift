import CoreMedia
import Foundation
import Libavcodec
import Testing
import VideoToolbox
@testable import LagoonEngine

@Suite("VP9 hardware decode")
struct VP9HardwareDecodeTests {
    private static let hardwareVP9 = PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true, hardwareVP9: true)

    private static func record(
        profile: Int32 = -99,
        level: Int32 = -99,
        bitDepth: UInt8 = 8,
        chromaSubsampling: VP9ConfigurationRecord.ChromaSubsampling = .colocated420,
        fullRange: Bool = false,
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Double = 30,
        colour: (UInt8, UInt8, UInt8) = (1, 1, 1)
    ) -> VP9ConfigurationRecord {
        VP9ConfigurationRecord(
            profile: profile, level: level, bitDepth: bitDepth, chromaSubsampling: chromaSubsampling,
            fullRange: fullRange, width: width, height: height, frameRate: frameRate,
            colourPrimaries: colour.0, transferCharacteristics: colour.1, matrixCoefficients: colour.2
        )
    }

    // MARK: The record

    @Test func anEightBit420StreamWritesProfile0() {
        // 3840x1632 at 23.976: too large a picture for level 4.1, so 5.
        let payload = Self.record(width: 3840, height: 1632, frameRate: 24000.0 / 1001).payload
        #expect(Array(payload) == [1, 0, 0, 0, 0, 50, 0x82, 1, 1, 1, 0, 0])
    }

    @Test func aTenBitPQStreamWritesProfile2AndItsColour() {
        let payload = Self.record(
            bitDepth: 10, width: 3840, height: 2160, frameRate: 60, colour: (9, 16, 9)
        ).payload
        #expect(Array(payload) == [1, 0, 0, 0, 2, 51, 0xA2, 9, 16, 9, 0, 0])
    }

    @Test func aFullRangeStreamSetsTheRangeBitAndKeepsItsChromaSiting() {
        let payload = Self.record(chromaSubsampling: .vertical420, fullRange: true).payload
        #expect(Array(payload) == [1, 0, 0, 0, 0, 40, 0x81, 1, 1, 1, 0, 0])
    }

    @Test func aStatedProfileAndLevelAreKeptAndMissingOnesDerived() {
        let stated = Self.record(profile: 2, level: 31, bitDepth: 10)
        #expect(stated.profile == 2)
        #expect(stated.level == 31)
        #expect(Self.record(chromaSubsampling: .chroma422).profile == 1)
        #expect(Self.record(bitDepth: 12, chromaSubsampling: .chroma444).profile == 3)
        #expect(Self.record(bitDepth: 10).profile == 2)
    }

    @Test func theLevelIsTheLowestThatHoldsThePictureAndItsRate() {
        #expect(VP9ConfigurationRecord.level(width: 160, height: 90, frameRate: 24) == 10)
        #expect(VP9ConfigurationRecord.level(width: 1280, height: 720, frameRate: 30) == 31)
        #expect(VP9ConfigurationRecord.level(width: 1920, height: 1080, frameRate: 30) == 40)
        #expect(VP9ConfigurationRecord.level(width: 1920, height: 1080, frameRate: 60) == 41)
        #expect(VP9ConfigurationRecord.level(width: 3840, height: 2160, frameRate: 30) == 50)
        #expect(VP9ConfigurationRecord.level(width: 3840, height: 2160, frameRate: 60) == 51)
        #expect(VP9ConfigurationRecord.level(width: 7680, height: 4320, frameRate: 30) == 60)
        // An unknown rate counts as 30, an unknown size as no level.
        #expect(VP9ConfigurationRecord.level(width: 1920, height: 1080, frameRate: 0) == 40)
        #expect(VP9ConfigurationRecord.level(width: 0, height: 0, frameRate: 30) == 0)
        #expect(VP9ConfigurationRecord.level(width: 16384, height: 16384, frameRate: 120) == 0)
    }

    @Test func onlyThe420ProfilesAreOfferedToHardware() {
        #expect(Self.record(chromaSubsampling: .colocated420).is420)
        #expect(Self.record(chromaSubsampling: .vertical420).is420)
        #expect(!Self.record(chromaSubsampling: .chroma422).is420)
        #expect(!Self.record(chromaSubsampling: .chroma444).is420)
    }

    // MARK: The route

    @Test func vp9GoesToVideoToolboxOnlyWhereTheDeviceDecodesItInHardware() {
        #expect(FFmpegDemuxer.usesCompressedVideoPath(codecID: AV_CODEC_ID_VP9, capabilities: Self.hardwareVP9))
        #expect(!FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_VP9,
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        ))
        #expect(!FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_VP9, capabilities: Self.hardwareVP9, outsideHardwareProfile: true
        ))
        #expect(!PlaybackCapabilities(hardwareHEVC: true).hardwareVP9)
        #expect(Self.hardwareVP9.hardwareVP9)
    }

    @Test func aRefusedSessionNamesTheSoftwareRouteToReopenOn() {
        var asked: [Bool] = []
        let refuse: (Bool) -> Bool = { asked.append($0); return false }
        let accept: (Bool) -> Bool = { asked.append($0); return true }
        #expect(VideoToolboxRefusal.softwareRoute(codecName: "vp9", outputsDecodedVideo: false, canDecode: refuse) == .vp9)
        #expect(VideoToolboxRefusal.softwareRoute(codecName: "av1", outputsDecodedVideo: false, canDecode: refuse) == .av1)
        // VP9 is asked for hardware, AV1 for any session.
        #expect(asked == [true, false])
        #expect(VideoToolboxRefusal.softwareRoute(codecName: "vp9", outputsDecodedVideo: false, canDecode: accept) == nil)
        #expect(VideoToolboxRefusal.softwareRoute(codecName: "av1", outputsDecodedVideo: false, canDecode: accept) == nil)
        asked = []
        #expect(VideoToolboxRefusal.softwareRoute(codecName: "vp9", outputsDecodedVideo: true, canDecode: refuse) == nil)
        #expect(VideoToolboxRefusal.softwareRoute(codecName: "hevc", outputsDecodedVideo: false, canDecode: refuse) == nil)
        #expect(VideoToolboxRefusal.softwareRoute(codecName: nil, outputsDecodedVideo: false, canDecode: refuse) == nil)
        #expect(asked.isEmpty)
    }

    // MARK: The demuxer, on `vp9.mkv` (testsrc2 160x90 at 24 fps, 8-bit 4:2:0)

    private static func fixture() throws -> String {
        try #require(Bundle.module.url(forResource: "SeekLanding/vp9.mkv", withExtension: nil)).path
    }

    @Test func withHardwareTheStreamOpensCompressedUnderASynthesizedRecord() throws {
        let demuxer = FFmpegDemuxer(capabilities: Self.hardwareVP9)
        defer { demuxer.close() }
        try demuxer.open(url: try Self.fixture(), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        #expect(!demuxer.outputsDecodedVideo)
        let description = try #require(demuxer.videoStream?.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_VP9)
        let atoms = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Data]
        let record = try #require(atoms?["vpcC"])
        #expect(record.count == 12)
        #expect(Array(record.prefix(7)) == [1, 0, 0, 0, 0, 10, 0x82])
        #expect(Array(record.suffix(2)) == [0, 0])
    }

    @Test func withoutHardwareTheStreamDecodesInSoftware() throws {
        let demuxer = FFmpegDemuxer(capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true))
        defer { demuxer.close() }
        try demuxer.open(url: try Self.fixture(), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        #expect(demuxer.outputsDecodedVideo)
    }

    /// The engine's sequence when VideoToolbox will not make the session: ask,
    /// close, switch the route off, reopen.
    @Test func aRefusedStreamReopensOnTheSoftwareDecoder() throws {
        let demuxer = FFmpegDemuxer(capabilities: Self.hardwareVP9)
        defer { demuxer.close() }
        let fixture = try Self.fixture()
        try demuxer.open(url: fixture, recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        let refused = VideoToolboxRefusal.softwareRoute(
            codecName: demuxer.videoStream?.codecName,
            outputsDecodedVideo: demuxer.outputsDecodedVideo,
            canDecode: { _ in false }
        )
        #expect(refused == .vp9)
        demuxer.close()
        demuxer.disableVideoToolboxVP9()
        try demuxer.open(url: fixture, recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        #expect(demuxer.outputsDecodedVideo)
        #expect(demuxer.videoStream?.codecName == "vp9")
    }

    #if targetEnvironment(simulator)
    /// The simulator decodes nothing in hardware, so asking for hardware is
    /// refused there even for H.264, which its software decoder opens, and
    /// VP9 takes the software route.
    @Test func askingForHardwareIsRefusedWhereThereIsNone() throws {
        let h264 = FFmpegDemuxer()
        defer { h264.close() }
        let h264Fixture = try #require(Bundle.module.url(forResource: "PresentationOrder/normal.mp4", withExtension: nil))
        try h264.open(url: h264Fixture.path, recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        let h264Description = try #require(h264.videoStream?.formatDescription)
        #expect(VideoToolboxDecoder.canDecode(h264Description))
        #expect(!VideoToolboxDecoder.canDecode(h264Description, requiringHardware: true))

        let vp9 = FFmpegDemuxer(capabilities: Self.hardwareVP9)
        defer { vp9.close() }
        try vp9.open(url: try Self.fixture(), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        let vp9Description = try #require(vp9.videoStream?.formatDescription)
        #expect(!VideoToolboxDecoder.canDecode(vp9Description, requiringHardware: true))
    }
    #endif
}
