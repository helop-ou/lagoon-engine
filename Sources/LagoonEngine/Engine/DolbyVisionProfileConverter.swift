import Dovi
import Foundation
import Libavutil
import OSLog

nonisolated private let log = Logger(subsystem: "ee.helop.lagoon", category: "dovi-p7")

/// How a single-track Dolby Vision profile 7 stream (base layer plus type-62
/// RPU and type-63 enhancement-layer NALs) reaches the decoder.
nonisolated enum DolbyVisionProfile7Mode: Sendable, Equatable {
    /// Default: convert RPUs to profile 8.1, drop the enhancement layer.
    case convert
    /// Drop both unit types; the base layer plays as HDR10.
    case stripToHDR10
}

/// One playback's profile 7 rewrite counts, for the HUD and the bench.
nonisolated struct DolbyVisionRewriteStats: Equatable, Sendable {
    var mode: DolbyVisionProfile7Mode
    /// Packets that carried a type 62 or 63 unit.
    var packets: Int = 0
    var rpusConverted: Int = 0
    /// Type 62 units removed: strip mode, or a failed conversion.
    var rpusDropped: Int = 0
    /// Type 63 units removed.
    var enhancementUnitsDropped: Int = 0
    var bytesRemoved: Int64 = 0
    /// libdovi parse/convert/write failures.
    var errors: Int = 0
    /// "FEL" or "MEL", from the first RPU header successfully read.
    var enhancementLayerType: String?
}

/// Rewrites Dolby Vision profile 7 to 8.1 packet by packet, so tvOS plays
/// real Dolby Vision instead of the HDR10 base layer.
///
/// Each RPU goes through `dovi_convert_rpu_with_mode(rpu, 2)` (as
/// `dovi_tool -m 2`). Mode 2, not 4, because it resets a FEL source's mapping
/// curves to identity; they only make sense with the residual. Type-63 units
/// are dropped. A failed RPU is dropped and counted, never stalls the stream.
/// Runs on the demux queue; `stats` is locked because the HUD reads it.
nonisolated final class DolbyVisionProfileConverter {
    /// dvvC for the converted stream: profile 8, single layer, level and
    /// version from the container's record.
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

    /// Rewrites one packet. nil when nothing changed or the payload does not
    /// parse, as `HEVCNALUnitRewriter.rewrite`.
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

        // nil: no 62/63 unit, or the payload did not parse. Pass through
        // with nothing counted.
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

    /// Parses, converts and re-escapes one type-62 unit (header byte first,
    /// no length prefix).
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

    /// Whether `byteCount` fits a `lengthSize`-byte prefix.
    private static func fits(byteCount: Int, lengthSize: Int) -> Bool {
        byteCount <= (1 << (8 * lengthSize)) - 1
    }
}
