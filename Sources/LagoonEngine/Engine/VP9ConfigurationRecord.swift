import Foundation
import Libavcodec
import Libavutil

/// The `vpcC` record VideoToolbox needs to open a VP9 session.
///
/// WebM and Matroska carry none, and FFmpeg's MP4 demuxer parses the one it
/// finds without keeping it, so it is always written here from what the probe
/// read out of the stream. The layout is the VP Codec ISO Media File Format
/// Binding's `VPCodecConfigurationBox`, version 1.
nonisolated struct VP9ConfigurationRecord: Equatable {
    /// 4:2:0 with chroma sited between luma rows, 4:2:0 sited with luma,
    /// 4:2:2, 4:4:4. The raw values are the binding's.
    enum ChromaSubsampling: UInt8 {
        case vertical420 = 0
        case colocated420 = 1
        case chroma422 = 2
        case chroma444 = 3
    }

    var profile: UInt8
    /// Ten times the level: 4.1 is 41.
    var level: UInt8
    var bitDepth: UInt8
    var chromaSubsampling: ChromaSubsampling
    var fullRange: Bool
    /// ISO/IEC 23001-8 code points, which FFmpeg's colour enums share.
    var colourPrimaries: UInt8
    var transferCharacteristics: UInt8
    var matrixCoefficients: UInt8

    /// The box payload: version and flags, the fields, and no codec
    /// initialization data, which VP9 has none of.
    var payload: Data {
        Data([
            1, 0, 0, 0,
            profile,
            level,
            bitDepth << 4 | chromaSubsampling.rawValue << 1 | (fullRange ? 1 : 0),
            colourPrimaries,
            transferCharacteristics,
            matrixCoefficients,
            0, 0,
        ])
    }

    /// Whether Apple's decoder takes the stream: profiles 0 and 2, the 4:2:0
    /// ones. Profiles 1 and 3 stay on the software path.
    var is420: Bool {
        chromaSubsampling == .vertical420 || chromaSubsampling == .colocated420
    }

    /// nil when the probe did not settle the pixel format.
    init?(codecpar: UnsafePointer<AVCodecParameters>, frameRate: Double) {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_VP9,
              let layout = av_pix_fmt_desc_get(AVPixelFormat(rawValue: codecpar.pointee.format)) else { return nil }
        let depth = UInt8(clamping: layout.pointee.comp.0.depth)
        let subsampling: ChromaSubsampling
        switch (layout.pointee.log2_chroma_w, layout.pointee.log2_chroma_h) {
        case (1, 1):
            subsampling = codecpar.pointee.chroma_location == AVCHROMA_LOC_LEFT ? .vertical420 : .colocated420
        case (1, 0):
            subsampling = .chroma422
        case (0, 0):
            subsampling = .chroma444
        default:
            return nil
        }
        self.init(
            profile: codecpar.pointee.profile,
            level: codecpar.pointee.level,
            bitDepth: depth,
            chromaSubsampling: subsampling,
            fullRange: codecpar.pointee.color_range == AVCOL_RANGE_JPEG,
            width: Int(codecpar.pointee.width),
            height: Int(codecpar.pointee.height),
            frameRate: frameRate,
            colourPrimaries: UInt8(clamping: codecpar.pointee.color_primaries.rawValue),
            transferCharacteristics: UInt8(clamping: codecpar.pointee.color_trc.rawValue),
            matrixCoefficients: UInt8(clamping: codecpar.pointee.color_space.rawValue)
        )
    }

    /// A profile or level the container does not state (negative) is derived:
    /// the profile from depth and subsampling, the level from picture size
    /// and rate.
    init(
        profile: Int32,
        level: Int32,
        bitDepth: UInt8,
        chromaSubsampling: ChromaSubsampling,
        fullRange: Bool,
        width: Int,
        height: Int,
        frameRate: Double,
        colourPrimaries: UInt8,
        transferCharacteristics: UInt8,
        matrixCoefficients: UInt8
    ) {
        let is420 = chromaSubsampling == .vertical420 || chromaSubsampling == .colocated420
        self.profile = (0...3).contains(profile)
            ? UInt8(profile)
            : (bitDepth > 8 ? 2 : 0) + (is420 ? 0 : 1)
        self.level = (1...255).contains(level)
            ? UInt8(level)
            : Self.level(width: width, height: height, frameRate: frameRate)
        self.bitDepth = bitDepth
        self.chromaSubsampling = chromaSubsampling
        self.fullRange = fullRange
        self.colourPrimaries = colourPrimaries
        self.transferCharacteristics = transferCharacteristics
        self.matrixCoefficients = matrixCoefficients
    }

    /// The lowest level whose luma sample rate and picture size hold the
    /// stream, from the VP9 levels table. 0, undefined, when none does or the
    /// size is unknown. An unknown rate counts as 30.
    static func level(width: Int, height: Int, frameRate: Double) -> UInt8 {
        let pictureSize = Int64(width) * Int64(height)
        guard pictureSize > 0 else { return 0 }
        let rate = frameRate.isFinite && frameRate > 0 ? frameRate : 30
        let sampleRate = Int64((Double(pictureSize) * rate).rounded(.up))
        let levels: [(level: UInt8, sampleRate: Int64, pictureSize: Int64)] = [
            (10, 829_440, 36_864),
            (11, 2_764_800, 73_728),
            (20, 4_608_000, 122_880),
            (21, 9_216_000, 245_760),
            (30, 20_736_000, 552_960),
            (31, 36_864_000, 983_040),
            (40, 83_558_400, 2_228_224),
            (41, 160_432_128, 2_228_224),
            (50, 311_951_360, 8_912_896),
            (51, 588_251_136, 8_912_896),
            (52, 1_176_502_272, 8_912_896),
            (60, 1_176_502_272, 35_651_584),
            (61, 2_353_004_544, 35_651_584),
            (62, 4_706_009_088, 35_651_584),
        ]
        return levels.first { sampleRate <= $0.sampleRate && pictureSize <= $0.pictureSize }?.level ?? 0
    }
}
