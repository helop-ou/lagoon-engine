import Dovi
import Foundation
import Libavcodec
import Libavutil

/// The Dolby Vision record a single-layer HEVC stream is signalled with, when
/// the container's is wrong, unusable or missing.
///
/// - Profile 8.2 has an SDR base layer. Its record is dropped and the base
///   plays. (Profile 10, AV1, is never signalled, so 10.2 already plays its
///   base.)
/// - A profile 5 record over a stream whose VUI says BT.2020 PQ is checked
///   against the first RPU. When libdovi reads that RPU as profile 8, the
///   stream is an HDR10 base with Dolby Vision metadata, and signalling it as
///   profile 5 would show its YCbCr as IPTPQc2.
/// - A 10-bit Matroska HEVC stream with no record and no colorimetry is
///   checked the same way. When its first RPU reads as profile 5, it gets a
///   synthesized profile 5 record, or it shows as raw IPTPQc2, green and
///   purple.
/// - Profile 8 with a base layer compatibility id other than 1, 2 or 4 is
///   outside Dolby's spec, and VideoToolbox refuses a session for it (-12909
///   for id 6 on an Apple TV 4K with tvOS 27). It is signalled with the id
///   its base layer's transfer function names: 1 over PQ, 4 over HLG. Over
///   anything else the record is dropped, as for 8.2. Such a stream is often
///   a profile 7 disc without its enhancement layer, so the first RPU is
///   read too: metadata still written for a full enhancement layer is
///   converted as profile 7 is (`DolbyVisionProfileConverter`), because its
///   mapping curves assume a residual that is gone.
nonisolated enum DolbyVisionRecordPolicy {
    /// What the first RPU says about the stream.
    struct FirstRPU: Equatable {
        /// libdovi's guess at the profile.
        var profile: UInt8
        /// Profile 7 metadata written for a full enhancement layer (FEL).
        var expectsFullEnhancementLayer = false
    }

    /// What the policy reads from the stream, apart from its record.
    struct Stream: Equatable {
        var codecID: AVCodecID = AV_CODEC_ID_HEVC
        var profile: Int32 = AV_PROFILE_HEVC_MAIN_10
        var primaries: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED
        var transfer: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED
        var matrix: AVColorSpace = AVCOL_SPC_UNSPECIFIED
        var width: Int32 = 3840
        var height: Int32 = 2160
        /// Frames per second, or 0 when unknown.
        var frameRate: Double = 0

        init() {}

        init(codecpar: UnsafeMutablePointer<AVCodecParameters>, frameRate: Double) {
            codecID = codecpar.pointee.codec_id
            profile = codecpar.pointee.profile
            primaries = codecpar.pointee.color_primaries
            transfer = codecpar.pointee.color_trc
            matrix = codecpar.pointee.color_space
            width = codecpar.pointee.width
            height = codecpar.pointee.height
            self.frameRate = frameRate
        }

        var saysHDR10: Bool {
            primaries == AVCOL_PRI_BT2020
                && transfer == AVCOL_TRC_SMPTE2084
                && matrix == AVCOL_SPC_BT2020_NCL
        }

        var hasNoColorimetry: Bool {
            primaries == AVCOL_PRI_UNSPECIFIED
                && transfer == AVCOL_TRC_UNSPECIFIED
                && matrix == AVCOL_SPC_UNSPECIFIED
        }
    }

    /// Whether the record cannot be trusted without the first RPU's profile.
    static func needsFirstRPU(
        container: AVDOVIDecoderConfigurationRecord?,
        stream: Stream,
        isMatroska: Bool
    ) -> Bool {
        guard stream.codecID == AV_CODEC_ID_HEVC else { return false }
        if let container {
            return container.dv_profile == 5 && stream.saysHDR10
                || isOutOfSpecProfile8(container) && profile8CompatibilityID(for: stream) == 1
        }
        return isMatroska && stream.profile == AV_PROFILE_HEVC_MAIN_10 && stream.hasNoColorimetry
    }

    /// The record to signal, or nil to play the base layer. `firstRPUProfile`
    /// is libdovi's guess from the first RPU, read only when `needsFirstRPU`.
    static func signalled(
        container: AVDOVIDecoderConfigurationRecord?,
        stream: Stream,
        firstRPUProfile: UInt8?
    ) -> AVDOVIDecoderConfigurationRecord? {
        guard let container else {
            return firstRPUProfile == 5 ? synthesizedProfile5(for: stream) : nil
        }
        switch (container.dv_profile, container.dv_bl_signal_compatibility_id) {
        case (8, 2):
            return nil
        case (8, _) where isOutOfSpecProfile8(container):
            guard let compatibilityID = profile8CompatibilityID(for: stream) else { return nil }
            var signalled = container
            signalled.dv_bl_signal_compatibility_id = compatibilityID
            return signalled
        case (5, _) where firstRPUProfile == 8:
            return profile81(from: container)
        default:
            return container
        }
    }

    /// Whether an out-of-spec profile 8 stream's RPUs are converted as
    /// profile 7's are. An unreadable first RPU is no evidence, so the stream
    /// is only relabelled.
    static func convertsProfile7RPUs(
        container: AVDOVIDecoderConfigurationRecord?,
        stream: Stream,
        firstRPU: FirstRPU?
    ) -> Bool {
        guard let container, let firstRPU,
              isOutOfSpecProfile8(container),
              profile8CompatibilityID(for: stream) == 1 else { return false }
        return firstRPU.profile == 7 && firstRPU.expectsFullEnhancementLayer
    }

    private static func isOutOfSpecProfile8(_ record: AVDOVIDecoderConfigurationRecord) -> Bool {
        record.dv_profile == 8 && ![1, 2, 4].contains(record.dv_bl_signal_compatibility_id)
    }

    /// The compatibility id of the base layer the stream itself declares. An
    /// undeclared transfer function counts as PQ, the base of the disc
    /// remuxes these records come from.
    private static func profile8CompatibilityID(for stream: Stream) -> UInt8? {
        switch stream.transfer {
        case AVCOL_TRC_SMPTE2084, AVCOL_TRC_UNSPECIFIED: 1
        case AVCOL_TRC_ARIB_STD_B67: 4
        default: nil
        }
    }

    /// What libdovi reads from the first RPU in a length-prefixed packet. nil
    /// when there is none, or it fails its CRC32: libdovi can abort on a
    /// corrupt one.
    static func firstRPU(in payload: UnsafeRawBufferPointer, lengthSize: Int) -> FirstRPU? {
        guard let unit = HEVCNALUnitRewriter.firstUnit(ofType: 62, in: payload, lengthSize: lengthSize),
              let base = unit.baseAddress,
              DolbyVisionRPUChecksum.isIntact(unit: unit),
              let rpu = dovi_parse_unspec62_nalu(base.assumingMemoryBound(to: UInt8.self), unit.count) else {
            return nil
        }
        defer { dovi_rpu_free(rpu) }
        guard dovi_rpu_get_error(rpu) == nil, let header = dovi_rpu_get_header(rpu) else { return nil }
        defer { dovi_rpu_free_header(header) }
        return FirstRPU(
            profile: header.pointee.guessed_profile,
            expectsFullEnhancementLayer: header.pointee.el_type.map { String(cString: $0) } == "FEL"
        )
    }

    /// The lowest Dolby Vision level whose pixel rate and width hold the
    /// stream, from FFmpeg's `dv_levels`. An unknown frame rate counts as 60,
    /// so the level never understates the stream.
    static func level(for stream: Stream) -> UInt8 {
        let frameRate = stream.frameRate > 0 ? stream.frameRate : 60
        let pixelRate = Double(stream.width) * Double(stream.height) * frameRate
        for (index, limit) in levels.enumerated()
        where pixelRate <= Double(limit.pixelRate) && stream.width <= limit.width {
            return UInt8(index + 1)
        }
        return UInt8(levels.count)
    }

    private static let levels: [(pixelRate: Int64, width: Int32)] = [
        (1280 * 720 * 24, 1280),
        (1280 * 720 * 30, 1280),
        (1920 * 1080 * 24, 1920),
        (1920 * 1080 * 30, 2560),
        (1920 * 1080 * 60, 3840),
        (3840 * 2160 * 24, 3840),
        (3840 * 2160 * 30, 3840),
        (3840 * 2160 * 48, 3840),
        (3840 * 2160 * 60, 3840),
        (3840 * 2160 * 120, 3840),
        (3840 * 2160 * 120, 7680),
        (7680 * 4320 * 60, 7680),
        (7680 * 4320 * 120, 7680),
    ]

    private static func synthesizedProfile5(for stream: Stream) -> AVDOVIDecoderConfigurationRecord {
        AVDOVIDecoderConfigurationRecord(
            dv_version_major: 1,
            dv_version_minor: 0,
            dv_profile: 5,
            dv_level: level(for: stream),
            rpu_present_flag: 1,
            el_present_flag: 0,
            bl_present_flag: 1,
            dv_bl_signal_compatibility_id: 0,
            dv_md_compression: 0
        )
    }

    private static func profile81(from record: AVDOVIDecoderConfigurationRecord) -> AVDOVIDecoderConfigurationRecord {
        AVDOVIDecoderConfigurationRecord(
            dv_version_major: record.dv_version_major,
            dv_version_minor: record.dv_version_minor,
            dv_profile: 8,
            dv_level: record.dv_level,
            rpu_present_flag: 1,
            el_present_flag: 0,
            bl_present_flag: 1,
            dv_bl_signal_compatibility_id: 1,
            dv_md_compression: 0
        )
    }
}
