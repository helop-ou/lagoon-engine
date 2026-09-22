import AudioToolbox
import CoreMedia
import Foundation
import Libavcodec
import Libavutil

nonisolated private let avNoPTS = Int64.min // AV_NOPTS_VALUE
nonisolated private let eac3AtmosProfile: Int32 = 30 // AV_PROFILE_EAC3_DDP_ATMOS
// The media subtype Apple's own format descriptions show for E-AC3 JOC
// tracks ("Enhanced AC-3 with JOC") — no public CoreAudio constant.
nonisolated private let ec3JOCFormatID = AudioFormatID(0x6563_2B33) // 'ec+3'

/// Turns FFmpeg codec parameters and packets into the CoreMedia objects the
/// AVSampleBuffer* renderers eat.
///
/// The trick that makes the whole architecture cheap: Matroska stores
/// h264/hevc exactly like mp4 (avcC/hvcC extradata, length-prefixed NALs),
/// so demuxed packets can be wrapped as compressed CMSampleBuffers without a
/// payload copy. The display layer decodes H.264; Lagoon's VideoToolbox stage
/// decodes HEVC and hardware-supported AV1 ahead. Same for aac/ac3/eac3 audio:
/// CoreAudio decodes the
/// compressed packets handed to AVSampleBufferAudioRenderer.
nonisolated enum SampleBufferFactory {
    /// Whether an HEVC `hvcC` carries the VPS/SPS/PPS a decoder has to be
    /// configured with.
    ///
    /// hev1-style muxing is legal and leaves the arrays empty, repeating the
    /// parameter sets in-band instead. Nothing complains at the time:
    /// `CMVideoFormatDescriptionCreate` builds a description around such a
    /// record and returns `noErr`, and the refusal only arrives later, when
    /// `VTDecompressionSessionCreate` declines the session with -4. That
    /// reads as a hardware fault rather than a container one, which is
    /// exactly how it was first misread.
    static func hevcExtradataCarriesParameterSets(_ hvcc: Data) -> Bool {
        // 22 bytes of fixed header, then numOfArrays and the arrays.
        guard hvcc.count > 22 else { return false }
        let base = hvcc.startIndex
        var offset = base + 23
        var sawSPS = false
        var sawPPS = false
        for _ in 0..<Int(hvcc[base + 22]) {
            guard offset + 3 <= hvcc.endIndex else { return false }
            let nalType = hvcc[offset] & 0x3F
            let count = Int(hvcc[offset + 1]) << 8 | Int(hvcc[offset + 2])
            offset += 3
            for _ in 0..<count {
                guard offset + 2 <= hvcc.endIndex else { return false }
                let length = Int(hvcc[offset]) << 8 | Int(hvcc[offset + 1])
                offset += 2 + length
                guard offset <= hvcc.endIndex else { return false }
                if nalType == 33 { sawSPS = true }
                if nalType == 34 { sawPPS = true }
            }
        }
        return sawSPS && sawPPS
    }

    /// Parameter sets that supersede the container's record, in decoder
    /// order, together with the framing of the samples they describe.
    ///
    /// Two containers need this and for different reasons: one that declares
    /// no parameter sets at all and repeats them in-band, and one
    /// that declares them in a framing Apple's decoders do not read, which is
    /// every MPEG-TS the disc reader opens.
    nonisolated struct BitstreamParameterSets {
        let sets: [Data]
        /// Bytes prefixing each NAL in the samples, not in these sets.
        let nalUnitHeaderLength: Int32

        init(sets: [Data], nalUnitHeaderLength: Int32) {
            self.sets = sets
            self.nalUnitHeaderLength = nalUnitHeaderLength
        }
    }

    static func videoFormatDescription(
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        parameterSets: BitstreamParameterSets? = nil,
        dolbyVisionOverride: AVDOVIDecoderConfigurationRecord? = nil
    ) -> CMFormatDescription? {
        var codecType: CMVideoCodecType
        let atomKey: String
        switch codecpar.pointee.codec_id {
        case AV_CODEC_ID_H264:
            codecType = kCMVideoCodecType_H264
            atomKey = "avcC"
        case AV_CODEC_ID_HEVC:
            codecType = kCMVideoCodecType_HEVC
            atomKey = "hvcC"
        case AV_CODEC_ID_AV1:
            codecType = kCMVideoCodecType_AV1
            atomKey = "av1C"
        default:
            return nil
        }
        let containerRecord: Data? = if let extradata = codecpar.pointee.extradata,
                                         codecpar.pointee.extradata_size > 0 {
            Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        } else {
            nil
        }
        // A container that describes nothing is still openable when the
        // parameter sets arrive from the bitstream instead.
        guard containerRecord != nil || parameterSets != nil else { return nil }
        var atoms: [String: Data] = [:]
        if let containerRecord {
            atoms[atomKey] = containerRecord
        }
        var extensions: [CFString: Any] = [:]

        // Colorimetry tags. The display pipeline only engages
        // HDR/EDR when the format description declares what the bitstream
        // carries — untagged BT.2020+PQ renders as washed-out SDR.
        if let primaries = colorPrimaries(codecpar.pointee.color_primaries) {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
        }
        if let transfer = transferFunction(codecpar.pointee.color_trc) {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
        }
        if let matrix = yCbCrMatrix(codecpar.pointee.color_space) {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix
        }
        if let chromaLocation = chromaLocation(codecpar.pointee.chroma_location) {
            extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = chromaLocation
        }
        switch codecpar.pointee.color_range {
        case AVCOL_RANGE_JPEG:
            extensions[kCMFormatDescriptionExtension_FullRangeVideo] = kCFBooleanTrue
        case AVCOL_RANGE_MPEG:
            extensions[kCMFormatDescriptionExtension_FullRangeVideo] = kCFBooleanFalse
        default:
            break
        }
        if let masteringDisplay = masteringDisplayColorVolume(codecpar) {
            extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = masteringDisplay
        }
        if let contentLight = contentLightLevel(codecpar) {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = contentLight
        }
        if let ambient = ambientViewingEnvironment(codecpar) {
            // Apple TN3145 requires custom sample-buffer playback to carry
            // `amve` through to presentation for correct HDR adaptation.
            extensions[kCMFormatDescriptionExtension_AmbientViewingEnvironment] = ambient
        }
        // Non-square pixels. Without this a 720x576 PAL DVD rip with a
        // 16:15 pixel aspect renders squished to its coded 5:4 box instead
        // of the 4:3 it was authored as.
        if let aspect = pixelAspectRatio(codecpar.pointee.sample_aspect_ratio) {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: aspect.horizontal,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: aspect.vertical,
            ]
        }

        // Dolby Vision, single-layer profiles only. Profile 5 (IPTPQc2) is
        // meaningless without the DoVi decode path, so the sample entry
        // itself becomes dvh1; profile 8 keeps hvc1 with a supplementary
        // dvvC so non-DoVi displays fall back to the base layer's
        // HDR10/HLG/SDR tags. Dual-layer profile 4 gets no atom — nothing
        // rewrites it, so it plays as HDR10 via the tags above. Profile 7
        // (UHD Blu-ray remuxes) is tagged the same way as profile 8
        // whenever the demuxer hands in `dolbyVisionOverride` — its RPUs
        // have been rewritten to profile 8.1 in flight — and
        // otherwise gets no atom, same as profile 4, which is the debug
        // HDR10 fallback (Settings → Advanced → Playback Diagnostics →
        // "Dolby Vision Compatibility Mode").
        if let dolbyVisionOverride {
            atoms["dvvC"] = doviConfigurationBox(dolbyVisionOverride)
        } else if codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
           let dovi = doviConfiguration(codecpar: codecpar) {
            switch dovi.dv_profile {
            case 5:
                codecType = kCMVideoCodecType_DolbyVisionHEVC
                atoms["dvcC"] = doviConfigurationBox(dovi)
            case 8:
                atoms["dvvC"] = doviConfigurationBox(dovi)
            default:
                break
            }
        }

        // Built from the bitstream's own parameter sets, which carry the
        // geometry and profile the empty container record could not. The
        // colorimetry above still applies and is passed through; the Dolby
        // Vision atoms — `dolbyVisionOverride` included — are not, because
        // this path only runs for a container that failed to describe its
        // own bitstream and its DoVi signalling is not worth more trust
        // than its parameter sets were. In practice this never carries a
        // profile 7 override anyway: it's MPEG-TS discs that need the
        // bitstream harvest, and those never have a DoVi configuration
        // record to convert in the first place. The base layer
        // still presents as HDR10 off the tags either way.
        if let parameterSets, !parameterSets.sets.isEmpty {
            switch codecpar.pointee.codec_id {
            case AV_CODEC_ID_HEVC:
                return hevcFormatDescription(
                    parameterSets: parameterSets.sets,
                    nalUnitHeaderLength: parameterSets.nalUnitHeaderLength,
                    extensions: extensions
                )
            case AV_CODEC_ID_H264:
                return h264FormatDescription(
                    parameterSets: parameterSets.sets,
                    nalUnitHeaderLength: parameterSets.nalUnitHeaderLength,
                    extensions: extensions
                )
            default:
                break
            }
        }

        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: codecpar.pointee.width,
            height: codecpar.pointee.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    /// Runs `body` with the parameter sets flattened into one contiguous
    /// buffer: CoreMedia takes pointers into memory it does not own, so they
    /// have to outlive the call and sit next to each other.
    private static func withFlattened<T>(
        _ parameterSets: [Data],
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>>, UnsafeBufferPointer<Int>) -> T?
    ) -> T? {
        var flattened: [UInt8] = []
        var sizes: [Int] = []
        for set in parameterSets {
            sizes.append(set.count)
            flattened.append(contentsOf: set)
        }
        return flattened.withUnsafeBufferPointer { bytes -> T? in
            guard let base = bytes.baseAddress else { return nil }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base.advanced(by: offset))
                offset += size
            }
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    body(pointerBuffer, sizeBuffer)
                }
            }
        }
    }

    /// A copy of `description` carrying `extensions` alongside its own.
    ///
    /// The H.264 creator takes no extensions of its own, and colorimetry that
    /// never reaches the description renders BT.2020 PQ as washed-out SDR, so
    /// it is grafted on rather than dropped.
    private static func withExtensions(
        _ description: CMFormatDescription,
        _ extensions: [CFString: Any]
    ) -> CMFormatDescription? {
        guard !extensions.isEmpty else { return description }
        var merged = (CMFormatDescriptionGetExtensions(description) as? [CFString: Any]) ?? [:]
        for (key, value) in extensions {
            merged[key] = value
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        var updated: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: CMFormatDescriptionGetMediaSubType(description),
            width: dimensions.width,
            height: dimensions.height,
            extensions: merged as CFDictionary,
            formatDescriptionOut: &updated
        )
        // Keeping the untagged description beats losing the decoder over a
        // colour tag.
        return status == noErr ? updated : description
    }

    private static func h264FormatDescription(
        parameterSets: [Data],
        nalUnitHeaderLength: Int32,
        extensions: [CFString: Any]
    ) -> CMFormatDescription? {
        withFlattened(parameterSets) { pointers, sizes in
            var description: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers.baseAddress!,
                parameterSetSizes: sizes.baseAddress!,
                nalUnitHeaderLength: nalUnitHeaderLength,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else { return nil }
            // CMVideoFormatDescriptionCreateFromH264ParameterSets takes no
            // extensions, so the colorimetry has to be grafted on afterwards.
            return withExtensions(description, extensions)
        }
    }

    /// Flattened so the parameter sets stay alive, and contiguous, for the
    /// duration of the call.
    private static func hevcFormatDescription(
        parameterSets: [Data],
        nalUnitHeaderLength: Int32,
        extensions: [CFString: Any]
    ) -> CMFormatDescription? {
        var flattened: [UInt8] = []
        var sizes: [Int] = []
        for set in parameterSets {
            sizes.append(set.count)
            flattened.append(contentsOf: set)
        }
        var description: CMFormatDescription?
        let status: OSStatus = flattened.withUnsafeBufferPointer { bytes in
            guard let base = bytes.baseAddress else { return errSecParam }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base.advanced(by: offset))
                offset += size
            }
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: nalUnitHeaderLength,
                        extensions: extensions as CFDictionary,
                        formatDescriptionOut: &description
                    )
                }
            }
        }
        return status == noErr ? description : nil
    }

    /// The stream's non-square pixel geometry, or nil when it is square, near
    /// enough to be invisible, or unknown (libavformat reports 0/1).
    ///
    /// nil rather than 1:1 keeps every format description that works today
    /// byte-identical: this is on the path of every h264/hevc title, and the
    /// same description goes to `AVDisplayCriteria` and
    /// `VTDecompressionSessionCreate`.
    ///
    /// The 1% tolerance matters as much. Real files carry rounding artifacts —
    /// 1744:1745 on a 4K remux, 180224:180219 on an AVI — and honouring those
    /// would change those descriptions to correct a hundredth of a percent.
    /// Genuine anamorphic PARs are far coarser: 16:15, 12:11, 32:27 and 64:45
    /// are all at least 6% off square.
    static func pixelAspectRatio(_ sar: AVRational) -> (horizontal: Int32, vertical: Int32)? {
        guard sar.num > 0, sar.den > 0 else { return nil }
        // Exact integer form of |num/den - 1| >= 1%.
        let numerator = Int64(sar.num)
        let denominator = Int64(sar.den)
        guard abs(numerator - denominator) * 100 >= denominator else { return nil }
        return (sar.num, sar.den)
    }

    /// Returns the description plus the codec's frames-per-packet (for
    /// fallback durations). aac needs its AudioSpecificConfig as the magic
    /// cookie; ac3/eac3 are self-describing.
    static func audioFormatDescription(codecpar: UnsafeMutablePointer<AVCodecParameters>) -> (CMFormatDescription, framesPerPacket: Int)? {
        var formatID: AudioFormatID
        var cookie: Data?
        var atoms: [String: Data]?
        var forcedChannels: UInt32?
        switch codecpar.pointee.codec_id {
        case AV_CODEC_ID_AAC:
            formatID = kAudioFormatMPEG4AAC
            if let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 {
                cookie = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            }
        case AV_CODEC_ID_AC3:
            formatID = kAudioFormatAC3
        case AV_CODEC_ID_EAC3:
            formatID = kAudioFormatEnhancedAC3
            // M2, settled on hardware (2026-08-17) after three failed
            // signalling attempts: what engages Atmos is the 'ec+3' media
            // subtype plus the 16-channel "16/JOC" presentation — the
            // exact shape of Apple's own JOC format descriptions. The
            // dec3 box rides along as the codec config; an Atmos channel
            // layout tag is NOT part of the recipe (with it, or with the
            // plain ec-3 subtype, the system decodes only the DD+ core
            // and reports "Multichannel").
            let isAtmos = codecpar.pointee.profile == eac3AtmosProfile
            cookie = dec3Payload(codecpar: codecpar, atmos: isAtmos)
            atoms = cookie.map { ["dec3": $0] }
            if isAtmos {
                formatID = ec3JOCFormatID
                forcedChannels = 16
            }
        case AV_CODEC_ID_MP3:
            formatID = kAudioFormatMPEGLayer3
        default:
            return nil
        }

        guard let framesPerPacket = audioFramesPerPacket(
            codecID: codecpar.pointee.codec_id,
            sampleRate: codecpar.pointee.sample_rate,
            declaredFrameSize: codecpar.pointee.frame_size
        ) else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(codecpar.pointee.sample_rate),
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: forcedChannels ?? UInt32(max(codecpar.pointee.ch_layout.nb_channels, 1)),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var extensions: CFDictionary?
        if let atoms {
            extensions = [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
            ] as CFDictionary
        }
        var description: CMFormatDescription?
        let status: OSStatus = (cookie ?? Data()).withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: cookie?.count ?? 0,
                magicCookie: cookie != nil ? bytes.baseAddress : nil,
                extensions: extensions,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else { return nil }
        return (description, framesPerPacket)
    }

    /// Prefer FFmpeg's parsed frame size (including 960-sample AAC), then
    /// fall back to the codec's packet cadence when the container omitted it.
    static func audioFramesPerPacket(
        codecID: AVCodecID,
        sampleRate: Int32,
        declaredFrameSize: Int32
    ) -> Int? {
        if declaredFrameSize > 0 {
            return Int(declaredFrameSize)
        }
        switch codecID {
        case AV_CODEC_ID_AAC:
            return 1024
        case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3:
            return 1536
        case AV_CODEC_ID_MP3:
            // MPEG-2/2.5 Layer III carries 576 samples; MPEG-1 carries 1152.
            return sampleRate > 0 && sampleRate <= 24_000 ? 576 : 1152
        default:
            return nil
        }
    }

    /// EC3SpecificBox (dec3) payload per ETSI TS 102 366 Annex F —
    /// synthesized from codec parameters the way FFmpeg's mp4 muxer does
    /// when remuxing E-AC3 out of MKV. One independent substream; 7.1
    /// adds the dependent-substream channel location for the back pair.
    private static func dec3Payload(codecpar: UnsafeMutablePointer<AVCodecParameters>, atmos: Bool) -> Data? {
        let fscod: UInt32 = switch codecpar.pointee.sample_rate {
        case 44_100: 1
        case 32_000: 2
        default: 0 // 48 kHz
        }
        var acmod: UInt32 = 7 // 3/2 front/surround
        var lfeon: UInt32 = 1
        var dependentSubstreams: UInt32 = 0
        var channelLocation: UInt32 = 0
        switch codecpar.pointee.ch_layout.nb_channels {
        case 1:
            acmod = 1
            lfeon = 0
        case 2:
            acmod = 2
            lfeon = 0
        case 6:
            break // 5.1 defaults
        case 8: // 7.1: 5.1 core + Lrs/Rrs in a dependent substream
            dependentSubstreams = 1
            channelLocation = 0b0_0000_0010
        default:
            break
        }

        var packer = BitPacker()
        packer.append(UInt32(clamping: max(codecpar.pointee.bit_rate, 0) / 1000), bits: 13)
        packer.append(0, bits: 3) // num_ind_sub - 1
        packer.append(fscod, bits: 2)
        packer.append(16, bits: 5) // bsid: E-AC3
        packer.append(0, bits: 1) // reserved
        packer.append(0, bits: 1) // asvc
        packer.append(0, bits: 3) // bsmod
        packer.append(acmod, bits: 3)
        packer.append(lfeon, bits: 1)
        packer.append(0, bits: 3) // reserved
        packer.append(dependentSubstreams, bits: 4)
        if dependentSubstreams > 0 {
            packer.append(channelLocation, bits: 9)
        } else {
            packer.append(0, bits: 1) // reserved
        }
        if atmos {
            packer.append(0, bits: 7) // reserved
            packer.append(1, bits: 1) // flag_ec3_extension_type_a (JOC)
            packer.append(16, bits: 8) // complexity_index_type_a (objects)
        }
        return packer.finish()
    }

    /// MSB-first bit packing for the dec3 payload.
    private struct BitPacker {
        private var bytes: [UInt8] = []
        private var buffer: UInt32 = 0
        private var bufferedBits = 0

        mutating func append(_ value: UInt32, bits: Int) {
            for offset in stride(from: bits - 1, through: 0, by: -1) {
                buffer = (buffer << 1) | ((value >> UInt32(offset)) & 1)
                bufferedBits += 1
                if bufferedBits == 8 {
                    bytes.append(UInt8(buffer & 0xFF))
                    buffer = 0
                    bufferedBits = 0
                }
            }
        }

        mutating func finish() -> Data {
            if bufferedBits > 0 {
                bytes.append(UInt8((buffer << (8 - bufferedBits)) & 0xFF))
                buffer = 0
                bufferedBits = 0
            }
            return Data(bytes)
        }
    }

    /// Wraps one demuxed packet as a compressed CMSampleBuffer. Video keeps
    /// decode timestamps (packets arrive in decode order; the downstream
    /// decoder uses them for B-frame dependencies) and marks non-keyframes
    /// NotSync so post-seek behavior is correct.
    static func sampleBuffer(
        packet: UnsafeMutablePointer<AVPacket>,
        formatDescription: CMFormatDescription,
        timeBase: AVRational,
        isVideo: Bool,
        fallbackDuration: Double,
        isKeyFrame: Bool,
        timingOverride: CMSampleTimingInfo? = nil,
        payloadOverride: Data? = nil,
        markDroppableFrames: Bool = false
    ) -> CMSampleBuffer? {
        let size: Int
        let blockBuffer: CMBlockBuffer?
        if let payloadOverride {
            // A rewritten payload (the DoVi EL strip) no longer
            // aliases FFmpeg's allocation, so it is copied into a
            // CoreMedia-owned block instead of retained.
            size = payloadOverride.count
            blockBuffer = copiedBlockBuffer(payloadOverride)
        } else {
            size = Int(packet.pointee.size)
            blockBuffer = referencingBlockBuffer(packet: packet, size: size)
        }
        guard size > 0, let blockBuffer else { return nil }

        let timeScale = max(timeBase.den, 1)
        func time(_ value: Int64) -> CMTime {
            guard value != avNoPTS else { return .invalid }
            let scaled = value.multipliedReportingOverflow(by: Int64(timeBase.num))
            if !scaled.overflow {
                return CMTime(value: scaled.partialValue, timescale: timeScale)
            }
            // Media timestamps should never approach Int64 overflow in a
            // real file, but preserve the old floating-point fallback for a
            // malformed/extreme stream instead of rejecting the sample.
            let seconds = Double(value) * Double(timeBase.num) / Double(timeScale)
            return CMTime(seconds: seconds, preferredTimescale: 90_000)
        }
        var timing: CMSampleTimingInfo
        if let timingOverride {
            timing = timingOverride
        } else {
            let presentation = packet.pointee.pts != avNoPTS ? time(packet.pointee.pts) : time(packet.pointee.dts)
            let duration: CMTime = if packet.pointee.duration > 0 {
                time(packet.pointee.duration)
            } else if fallbackDuration > 0 {
                CMTime(seconds: fallbackDuration, preferredTimescale: 90_000)
            } else {
                .invalid
            }
            timing = CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: presentation,
                decodeTimeStamp: isVideo ? time(packet.pointee.dts) : .invalid
            )
        }

        var sampleSize = size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // Frame dependencies.
        //
        // CMSampleBuffer.h: "A frame is considered droppable if and only if
        // kCMSampleAttachmentKey_IsDependedOnByOthers is present and set to
        // kCFBooleanFalse." Absent means NOT droppable — the opposite of what
        // 4e2ad5f assumed. Setting it false on AV_PKT_FLAG_DISPOSABLE frames
        // licenses the renderer's pre-decode dropper for every non-reference
        // frame: 67% of the stream on the title measuring 10.7% steady loss at
        // a matched display rate with full queues. The sim A/B showing no
        // difference ran where that dropper never engages.
        //
        // So it is opt-in (debug.markDroppableFrames). By default NotSync and
        // DependsOnOthers stay — decode dependencies, not droppability — and
        // IsDependedOnByOthers is set true for reference frames only.
        if isVideo,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            func set(_ key: CFString, _ value: Bool) {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(key).toOpaque(),
                    Unmanaged.passUnretained(value ? kCFBooleanTrue : kCFBooleanFalse).toOpaque()
                )
            }
            let disposable = (packet.pointee.flags & AV_PKT_FLAG_DISPOSABLE) != 0
            if !isKeyFrame {
                set(kCMSampleAttachmentKey_NotSync, true)
            }
            set(kCMSampleAttachmentKey_DependsOnOthers, !isKeyFrame)
            if !disposable {
                set(kCMSampleAttachmentKey_IsDependedOnByOthers, true)
            } else if markDroppableFrames {
                set(kCMSampleAttachmentKey_IsDependedOnByOthers, false)
            }
        }
        return sampleBuffer
    }

    /// Whether a sample can start a decoder, as the sample itself says it.
    ///
    /// The answer to the question `PlaybackRendererStartPolicy` asks, read
    /// back out of the attachment written above. Absent means sync, which is
    /// also the right reading for a decoded frame carrying no attachments at
    /// all: nothing the renderer has to decode, nothing it can refuse.
    static func isSyncSample(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            buffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
            let first = attachments.first else { return true }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }

    /// The payload copied into a CoreMedia-owned block (same shape as
    /// `AudioDecoder.makeSampleBuffer` uses for LPCM — see the leak note
    /// there before ever "optimizing" this into a handoff).
    private static func copiedBlockBuffer(_ data: Data) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }
        let copied = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        return copied == noErr ? blockBuffer : nil
    }

    /// The zero-copy path: retain FFmpeg's payload allocation and hand
    /// CoreMedia a block that releases it after decode.
    private static func referencingBlockBuffer(
        packet: UnsafeMutablePointer<AVPacket>,
        size: Int
    ) -> CMBlockBuffer? {
        guard size > 0 else { return nil }
        // Keep only a reference to FFmpeg's underlying payload allocation.
        // Cloning the whole AVPacket is already zero-copy for its main data,
        // but still allocates a packet object and copies all packet side data
        // for every frame. CoreMedia needs the bytes and their lifetime, not
        // that metadata, so an AVBufferRef is the narrowest ownership token.
        if packet.pointee.buf == nil, av_packet_make_refcounted(packet) < 0 {
            return nil
        }
        guard let packetBuffer = packet.pointee.buf,
              let retainedBuffer = av_buffer_ref(packetBuffer) else { return nil }
        var ownedBuffer: UnsafeMutablePointer<AVBufferRef>? = retainedBuffer
        guard let retainedData = packet.pointee.data else {
            av_buffer_unref(&ownedBuffer)
            return nil
        }
        var blockSource = CMBlockBufferCustomBlockSource(
            version: UInt32(kCMBlockBufferCustomBlockSourceVersion),
            AllocateBlock: nil,
            FreeBlock: { refCon, _, _ in
                guard let refCon else { return }
                var buffer: UnsafeMutablePointer<AVBufferRef>? = refCon.assumingMemoryBound(to: AVBufferRef.self)
                av_buffer_unref(&buffer)
            },
            refCon: UnsafeMutableRawPointer(retainedBuffer)
        )
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: retainedData,
            blockLength: size,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &blockSource,
            offsetToData: 0,
            dataLength: size,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else {
            // Ownership transfers to CoreMedia only after successful block
            // creation; balance the reference on the failure path.
            av_buffer_unref(&ownedBuffer)
            return nil
        }
        return blockBuffer
    }

    // MARK: - HDR / Dolby Vision tagging

    static func colorPrimaries(_ primaries: AVColorPrimaries) -> CFString? {
        switch primaries {
        case AVCOL_PRI_BT709: kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT470BG: kCMFormatDescriptionColorPrimaries_EBU_3213
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: kCMFormatDescriptionColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT2020: kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE431: kCMFormatDescriptionColorPrimaries_DCI_P3
        case AVCOL_PRI_SMPTE432: kCMFormatDescriptionColorPrimaries_P3_D65
        default: nil
        }
    }

    static func transferFunction(_ transfer: AVColorTransferCharacteristic) -> CFString? {
        switch transfer {
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M: kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12: kCMFormatDescriptionTransferFunction_ITU_R_2020
        case AVCOL_TRC_SMPTE2084: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_SMPTE240M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995
        case AVCOL_TRC_IEC61966_2_1: kCMFormatDescriptionTransferFunction_sRGB
        case AVCOL_TRC_LINEAR: kCMFormatDescriptionTransferFunction_Linear
        default: nil
        }
    }

    static func yCbCrMatrix(_ space: AVColorSpace) -> CFString? {
        switch space {
        case AVCOL_SPC_BT709: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE240M: kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default: nil
        }
    }

    static func chromaLocation(_ location: AVChromaLocation) -> CFString? {
        switch location {
        case AVCHROMA_LOC_LEFT: kCMFormatDescriptionChromaLocation_Left
        case AVCHROMA_LOC_CENTER: kCMFormatDescriptionChromaLocation_Center
        case AVCHROMA_LOC_TOPLEFT: kCMFormatDescriptionChromaLocation_TopLeft
        case AVCHROMA_LOC_TOP: kCMFormatDescriptionChromaLocation_Top
        case AVCHROMA_LOC_BOTTOMLEFT: kCMFormatDescriptionChromaLocation_BottomLeft
        case AVCHROMA_LOC_BOTTOM: kCMFormatDescriptionChromaLocation_Bottom
        default: nil
        }
    }

    /// The stream's Dolby Vision configuration, when the container carries
    /// one — the demuxer uses it to decide whether a profile 7 stream gets
    /// converted to profile 8.1 or stripped to the HDR10 fallback (formerly
    /// a strip-only experiment).
    static func doviConfiguration(codecpar: UnsafeMutablePointer<AVCodecParameters>) -> AVDOVIDecoderConfigurationRecord? {
        sideData(codecpar, type: AV_PKT_DATA_DOVI_CONF)
    }

    /// Reads one typed side-data entry off the codec parameters (FFmpeg
    /// stores container-level HDR/DoVi metadata there after
    /// avformat_find_stream_info).
    static func sideData<T>(_ codecpar: UnsafeMutablePointer<AVCodecParameters>, type: AVPacketSideDataType) -> T? {
        guard let entry = av_packet_side_data_get(
            codecpar.pointee.coded_side_data,
            codecpar.pointee.nb_coded_side_data,
            type
        ), let data = entry.pointee.data, entry.pointee.size >= MemoryLayout<T>.size else {
            return nil
        }
        return UnsafeRawPointer(data).loadUnaligned(as: T.self)
    }

    /// Serializes AVMasteringDisplayMetadata as the 24-byte big-endian
    /// payload CoreMedia expects (SEI mastering_display_colour_volume /
    /// mdcv box): primaries in G,B,R order at 0.00002 steps, luminance at
    /// 0.0001 cd/m².
    static func masteringDisplayColorVolume(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Data? {
        guard let metadata: AVMasteringDisplayMetadata = sideData(codecpar, type: AV_PKT_DATA_MASTERING_DISPLAY_METADATA),
              metadata.has_primaries != 0, metadata.has_luminance != 0 else {
            return nil
        }
        let chromaticitySteps: Int64 = 50_000
        let luminanceSteps: Int64 = 10_000
        var payload = Data(capacity: 24)
        for primary in [metadata.display_primaries.1, metadata.display_primaries.2, metadata.display_primaries.0] {
            append(UInt16(clamping: rescale(primary.0, by: chromaticitySteps)), to: &payload)
            append(UInt16(clamping: rescale(primary.1, by: chromaticitySteps)), to: &payload)
        }
        append(UInt16(clamping: rescale(metadata.white_point.0, by: chromaticitySteps)), to: &payload)
        append(UInt16(clamping: rescale(metadata.white_point.1, by: chromaticitySteps)), to: &payload)
        append(UInt32(clamping: rescale(metadata.max_luminance, by: luminanceSteps)), to: &payload)
        append(UInt32(clamping: rescale(metadata.min_luminance, by: luminanceSteps)), to: &payload)
        return payload
    }

    /// 4-byte big-endian MaxCLL + MaxFALL (SEI content_light_level_info /
    /// clli box).
    static func contentLightLevel(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Data? {
        guard let metadata: AVContentLightMetadata = sideData(codecpar, type: AV_PKT_DATA_CONTENT_LIGHT_LEVEL),
              metadata.MaxCLL > 0 || metadata.MaxFALL > 0 else {
            return nil
        }
        var payload = Data(capacity: 4)
        append(UInt16(clamping: metadata.MaxCLL), to: &payload)
        append(UInt16(clamping: metadata.MaxFALL), to: &payload)
        return payload
    }

    /// The 8-byte big-endian `amve` / H.274 payload Apple uses for ambient
    /// HDR adaptation: illuminance at 1/10000 lux, then CIE x/y at 1/50000.
    static func ambientViewingEnvironment(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> Data? {
        guard let metadata: AVAmbientViewingEnvironment = sideData(
            codecpar,
            type: AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT
        ) else { return nil }
        return ambientViewingEnvironmentPayload(metadata)
    }

    static func ambientViewingEnvironmentPayload(
        _ metadata: AVAmbientViewingEnvironment
    ) -> Data? {
        guard metadata.ambient_illuminance.num > 0,
              metadata.ambient_illuminance.den > 0,
              metadata.ambient_light_x.den > 0,
              metadata.ambient_light_y.den > 0 else { return nil }
        var payload = Data(capacity: 8)
        append(UInt32(clamping: rescale(metadata.ambient_illuminance, by: 10_000)), to: &payload)
        append(UInt16(clamping: rescale(metadata.ambient_light_x, by: 50_000)), to: &payload)
        append(UInt16(clamping: rescale(metadata.ambient_light_y, by: 50_000)), to: &payload)
        return payload
    }

    /// The 24-byte DOVIDecoderConfigurationRecord (dvcC/dvvC payload),
    /// bit-for-bit the layout FFmpeg's own muxers emit in
    /// ff_isom_put_dvcc_dvvc.
    private static func doviConfigurationBox(_ record: AVDOVIDecoderConfigurationRecord) -> Data {
        var payload = Data(count: 24)
        payload[0] = record.dv_version_major
        payload[1] = record.dv_version_minor
        payload[2] = ((record.dv_profile & 0x7F) << 1) | ((record.dv_level & 0x3F) >> 5)
        payload[3] = ((record.dv_level & 0x1F) << 3)
            | (min(record.rpu_present_flag, 1) << 2)
            | (min(record.el_present_flag, 1) << 1)
            | min(record.bl_present_flag, 1)
        payload[4] = ((record.dv_bl_signal_compatibility_id & 0x0F) << 4)
            | ((record.dv_md_compression & 0x03) << 2)
        return payload
    }

    private static func rescale(_ value: AVRational, by steps: Int64) -> Int64 {
        let denominator = Int64(max(value.den, 1))
        return (Int64(value.num) * steps + denominator / 2) / denominator
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}
