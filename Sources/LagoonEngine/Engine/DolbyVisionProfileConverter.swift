import Dovi
import Foundation
import Libavutil
import OSLog

nonisolated private let log = Logger(subsystem: "ee.helop.lagoon", category: "dovi-p7")

/// Which way a single-track Dolby Vision profile 7 HEVC stream (a UHD
/// Blu-ray remux: base layer plus type-62 RPU and type-63 enhancement-layer
/// NAL units interleaved in one track) reaches the decoder.
nonisolated enum DolbyVisionProfile7Mode: Sendable, Equatable {
    /// Rewrite every RPU to profile 8.1 with libdovi and drop the
    /// enhancement layer, tagging the track for real Dolby Vision. Default.
    case convert
    /// The older behaviour: drop both unit types and let the base
    /// layer present as HDR10. Settings → Advanced → Playback Diagnostics
    /// → "Dolby Vision Compatibility Mode".
    case stripToHDR10
}

/// A snapshot of one playback's profile 7 rewrite, for the HUD and the
/// frame-loss bench's stdout line.
nonisolated struct DolbyVisionRewriteStats: Equatable, Sendable {
    var mode: DolbyVisionProfile7Mode
    /// Packets that carried a type 62 or 63 unit.
    var packets: Int = 0
    var rpusConverted: Int = 0
    /// Type 62 units removed — strip mode, or a conversion failure in
    /// convert mode.
    var rpusDropped: Int = 0
    /// Type 63 units removed.
    var enhancementUnitsDropped: Int = 0
    var bytesRemoved: Int64 = 0
    /// libdovi parse/convert/write failures.
    var errors: Int = 0
    /// "FEL" or "MEL", from the first RPU header successfully read.
    var enhancementLayerType: String?
}

/// Rewrites a single-track Dolby Vision profile 7 HEVC stream to profile
/// 8.1 in flight, packet by packet, so tvOS engages real Dolby Vision
/// instead of the HDR10-only base layer.
///
/// Every type-62 RPU is parsed with libdovi, converted with
/// `dovi_convert_rpu_with_mode(rpu, 2)` (the same transform `dovi_tool -m 2`
/// performs: enhancement-layer and NLQ signalling removed, DM coefficients
/// set for 8.1, and for a FEL source the base-layer mapping curves reset to
/// identity, since a FEL mapping was designed to be applied with the
/// residual — mode 4 would keep them) and written back escaped; every
/// type-63 enhancement-layer unit is dropped. A libdovi failure on one RPU drops that unit and counts an
/// error rather than stalling the stream. Used from the demuxer's serial
/// queue; `stats` is also read from the main actor for the HUD, so it is
/// guarded by a lock.
nonisolated final class DolbyVisionProfileConverter {
    /// The dvvC payload source for the converted stream: profile 8, level
    /// and version copied from the container's own record, single-layer
    /// RPU-only signalling.
    let synthesizedRecord: AVDOVIDecoderConfigurationRecord

    private let lock = NSLock()
    nonisolated(unsafe) private var mutableStats: DolbyVisionRewriteStats

    // Demux-queue only: `convert` is never called concurrently with itself.
    private var didReadHeader = false
    private var recordedEnhancementLayerType: String?

    var stats: DolbyVisionRewriteStats {
        lock.lock()
        defer { lock.unlock() }
        return mutableStats
    }

    /// nil unless `record.dv_profile == 7`.
    init?(record: AVDOVIDecoderConfigurationRecord) {
        guard record.dv_profile == 7 else { return nil }
        synthesizedRecord = AVDOVIDecoderConfigurationRecord(
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
        mutableStats = DolbyVisionRewriteStats(mode: .convert)
    }

    /// Rewrites one packet. Returns nil when the payload carries no type 62
    /// or 63 unit (so the zero-copy path stays in use) or does not parse —
    /// same contract as `HEVCNALUnitRewriter.rewrite`, which this is built
    /// on.
    func convert(payload: UnsafeRawBufferPointer, lengthSize: Int) -> Data? {
        var converted = 0
        var rpuDropped = 0
        var enhancementDropped = 0
        var errors = 0
        var bytesRemoved: Int64 = 0

        let result = HEVCNALUnitRewriter.rewrite(payload: payload, lengthSize: lengthSize) { nalType, unit in
            switch nalType {
            case 63:
                enhancementDropped += 1
                bytesRemoved += Int64(lengthSize + unit.count)
                return .drop
            case 62:
                switch self.convertRPU(unit: unit) {
                case .converted(let data):
                    guard Self.fits(byteCount: data.count, lengthSize: lengthSize) else {
                        rpuDropped += 1
                        errors += 1
                        bytesRemoved += Int64(lengthSize + unit.count)
                        return .drop
                    }
                    converted += 1
                    bytesRemoved += Int64(unit.count - data.count)
                    return .replace(data)
                case .failed:
                    rpuDropped += 1
                    errors += 1
                    bytesRemoved += Int64(lengthSize + unit.count)
                    return .drop
                }
            default:
                return .keep
            }
        }

        // Whenever a type 62/63 unit was seen, the walk above always
        // returns `.drop` or `.replace` for it, never `.keep`, so a
        // complete (non-malformed) walk is guaranteed to have changed
        // something and `rewrite` returns non-nil. A nil result here can
        // only mean the payload didn't parse — pass through untouched,
        // with nothing committed to `stats`, exactly like an unchanged one.
        guard let result else { return nil }

        lock.lock()
        mutableStats.packets += 1
        mutableStats.rpusConverted += converted
        mutableStats.rpusDropped += rpuDropped
        mutableStats.enhancementUnitsDropped += enhancementDropped
        mutableStats.errors += errors
        mutableStats.bytesRemoved += bytesRemoved
        if let recordedEnhancementLayerType, mutableStats.enhancementLayerType == nil {
            mutableStats.enhancementLayerType = recordedEnhancementLayerType
        }
        lock.unlock()

        return result
    }

    private enum RPUOutcome {
        case converted(Data)
        case failed
    }

    /// Parses, converts and re-escapes one type-62 unit. `unit` is the raw
    /// NAL bytes libdovi expects: header byte first, no length prefix.
    private func convertRPU(unit: UnsafeRawBufferPointer) -> RPUOutcome {
        guard let base = unit.baseAddress else { return .failed }
        guard let rpu = dovi_parse_unspec62_nalu(base.assumingMemoryBound(to: UInt8.self), unit.count) else {
            return .failed
        }
        defer { dovi_rpu_free(rpu) }
        if let error = dovi_rpu_get_error(rpu) {
            log.error("DoVi P7 RPU parse failed: \(String(cString: error), privacy: .public)")
            return .failed
        }

        if !didReadHeader {
            didReadHeader = true
            if let header = dovi_rpu_get_header(rpu) {
                let elType = header.pointee.el_type.map { String(cString: $0) }
                let guessedProfile = header.pointee.guessed_profile
                dovi_rpu_free_header(header)
                recordedEnhancementLayerType = elType
                log.info(
                    "DoVi P7 stream detected (guessed profile \(guessedProfile, privacy: .public), enhancement layer \(elType ?? "unknown", privacy: .public)) — converting RPUs to profile 8.1"
                )
            }
        }

        guard dovi_convert_rpu_with_mode(rpu, 2) == 0 else {
            if let error = dovi_rpu_get_error(rpu) {
                log.error("DoVi P7 RPU convert failed: \(String(cString: error), privacy: .public)")
            }
            return .failed
        }

        guard let written = dovi_write_unspec62_nalu(rpu) else { return .failed }
        defer { dovi_data_free(written) }
        guard written.pointee.len > 0, let dataPointer = written.pointee.data else {
            if let error = dovi_rpu_get_error(rpu) {
                log.error("DoVi P7 RPU write failed: \(String(cString: error), privacy: .public)")
            }
            return .failed
        }
        return .converted(Data(bytes: dataPointer, count: written.pointee.len))
    }

    /// Whether `byteCount` can be expressed in a `lengthSize`-byte
    /// big-endian prefix.
    private static func fits(byteCount: Int, lengthSize: Int) -> Bool {
        byteCount <= (1 << (8 * lengthSize)) - 1
    }
}
