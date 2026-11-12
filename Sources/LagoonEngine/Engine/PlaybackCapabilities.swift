import CoreMedia
import Foundation
import VideoToolbox

/// What the device can decode.
///
/// `VTIsHardwareDecodeSupported` reports hardware only, and is false for every
/// codec on the simulator, even H.264. So only query where it changes routing:
///
/// - HEVC requires hardware; without it the session fails with -12906.
/// - AV1 uses hardware where available, bounded libdav1d otherwise.
/// - VP9 uses hardware where available, libavcodec otherwise.
/// - H.264 goes to the renderer compressed; the rest are libavcodec on CPU.
///
/// A true is not a promise. The delivery ladder covers that.
public nonisolated struct PlaybackCapabilities: Equatable, Sendable {
    public let hardwareHEVC: Bool
    public let hardwareAV1: Bool
    /// Whether AV1 may be offered to VideoToolbox. Always true: VideoToolbox
    /// has a software AV1 decoder on some platforms, so the hardware query
    /// is the wrong question. `VideoToolboxDecoder.canDecode` settles it per
    /// stream; where it fails (-12906), the engine reopens on software.
    public var decodesAV1WithVideoToolbox: Bool { true }
    /// Whether the device decodes VP9 in hardware. VP9 is offered to
    /// VideoToolbox only then: its software route is libavcodec.
    public let hardwareVP9: Bool

    public init(hardwareHEVC: Bool, hardwareAV1: Bool = false, hardwareVP9: Bool = false) {
        self.hardwareHEVC = hardwareHEVC
        self.hardwareAV1 = hardwareAV1
        self.hardwareVP9 = hardwareVP9
    }

    /// Resolved once per process.
    private static let hardware = {
        registerSupplementalDecoders()
        return (
            hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            vp9: VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        )
    }()

    static public var current: PlaybackCapabilities {
        PlaybackCapabilities(hardwareHEVC: hardware.hevc, hardwareAV1: hardware.av1, hardwareVP9: hardware.vp9)
    }

    /// VP9 is a supplemental decoder: VideoToolbox neither reports nor opens
    /// it in a process that has not asked for it. Once per process, before
    /// the first query or session.
    static func registerSupplementalDecoders() {
        _ = supplementalDecodersRegistered
    }

    private static let supplementalDecodersRegistered: Void = {
        if #available(iOS 26.2, tvOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        }
    }()
}
