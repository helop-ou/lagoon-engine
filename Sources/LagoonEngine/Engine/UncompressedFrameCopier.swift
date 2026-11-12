import CoreMedia
import CoreVideo
import VideoToolbox

/// Copies a decoded frame into a plain 4:2:0 format the subtitle compositor
/// can write. On a device VideoToolbox hands the renderer compressed forms
/// of 4:2:0, which have no planes to draw into. The simulator decodes to
/// plain formats, so only devices take this path. Pump queue only.
nonisolated final class UncompressedFrameCopier {
    private struct PoolKey: Equatable {
        let format: OSType
        let width: Int
        let height: Int
    }

    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolKey: PoolKey?

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    /// The plain format with the same depth and range, or nil when the frame
    /// is not a compressed form of 4:2:0.
    static func uncompressedFormat(for pixelFormat: OSType) -> OSType? {
        switch pixelFormat {
        case kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange:
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        default:
            nil
        }
    }

    /// A sample buffer over a copy of the frame in `format`, with the
    /// original's timing and attachments, or nil if the copy failed.
    func copy(_ buffer: CMSampleBuffer, to format: OSType) -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(buffer),
              let frame = copy(source, to: format) else { return nil }
        var description: CMVideoFormatDescription?
        var timing = CMSampleTimingInfo()
        var copied: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                  allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &description
              ) == noErr,
              let description,
              CMSampleBufferGetSampleTimingInfo(buffer, at: 0, timingInfoOut: &timing) == noErr,
              CMSampleBufferCreateReadyWithImageBuffer(
                  allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescription: description,
                  sampleTiming: &timing, sampleBufferOut: &copied
              ) == noErr,
              let copied else { return nil }
        CMPropagateAttachments(buffer, destination: copied)
        // Display marks such as DoNotDisplay live per sample, not on the buffer.
        if let marks = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [NSDictionary])?.first,
           marks.count > 0,
           let target = (CMSampleBufferGetSampleAttachmentsArray(copied, createIfNecessary: true) as? [NSMutableDictionary])?.first {
            target.addEntries(from: marks as! [AnyHashable: Any])
        }
        return copied
    }

    private func copy(_ source: CVPixelBuffer, to format: OSType) -> CVPixelBuffer? {
        let key = PoolKey(format: format, width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        if key != poolKey {
            pool = Self.makePool(key)
            poolKey = pool == nil ? nil : key
        }
        if session == nil {
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        }
        var frame: CVPixelBuffer?
        guard let pool, let session,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &frame) == kCVReturnSuccess,
              let frame else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: frame) == noErr else { return nil }
        return frame
    }

    private static func makePool(_ key: PoolKey) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: key.format,
            kCVPixelBufferWidthKey as String: key.width,
            kCVPixelBufferHeightKey as String: key.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }
}
