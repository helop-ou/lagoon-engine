import CoreMedia
import Foundation

/// Tells pictures no other picture references. A seek lands on the keyframe
/// before its target, and the pictures in between are decoded only to reach
/// it. Those nothing references need not be decoded at all: half of the
/// pictures in F1 S07E01 (HEVC, one temporal layer) are `TRAIL_N`.
nonisolated struct UnreferencedPictureReader: Sendable {
    let codec: VideoRandomAccessPoint.Codec
    let lengthSize: Int
    /// HEVC: a sub-layer non-reference picture is unreferenced only in the
    /// highest sub-layer, since a higher one may still reference it.
    let highestTemporalID: UInt8

    init(codec: VideoRandomAccessPoint.Codec, lengthSize: Int, highestTemporalID: UInt8 = 0) {
        self.codec = codec
        self.lengthSize = lengthSize
        self.highestTemporalID = highestTemporalID
    }

    /// From the `avcC` or `hvcC` record. Nil for other codecs, and for HEVC
    /// whose record does not say how many temporal layers it has.
    init?(formatDescription: CMFormatDescription) {
        let atoms = CMFormatDescriptionGetExtension(
            formatDescription,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any]
        if let record = atoms?["avcC"] as? Data,
           let size = VideoRandomAccessPoint.nalLengthSize(configurationRecord: record, codec: .h264) {
            self.init(codec: .h264, lengthSize: size)
        } else if let record = atoms?["hvcC"] as? Data,
                  let size = VideoRandomAccessPoint.nalLengthSize(configurationRecord: record, codec: .hevc) {
            let layers = (record[record.startIndex + 21] >> 3) & 0x7
            guard layers > 0 else { return nil }
            self.init(codec: .hevc, lengthSize: size, highestTemporalID: layers - 1)
        } else {
            return nil
        }
    }

    /// False when the payload does not parse or has no picture in it.
    func isUnreferenced(_ payload: UnsafeRawBufferPointer) -> Bool {
        guard payload.baseAddress != nil, (1...4).contains(lengthSize) else { return false }
        var offset = 0
        var sawPicture = false
        while offset < payload.count {
            guard offset + lengthSize <= payload.count else { return false }
            var length = 0
            for index in 0..<lengthSize {
                length = length << 8 | Int(payload[offset + index])
            }
            let start = offset + lengthSize
            guard length >= 2, start + length <= payload.count else { return false }
            let header = payload[start]
            switch codec {
            case .h264:
                let type = header & 0x1F
                if (1...5).contains(type) {
                    guard (header >> 5) & 0x3 == 0 else { return false }
                    sawPicture = true
                }
            case .hevc:
                let type = (header >> 1) & 0x3F
                if type < 32 {
                    let temporalID = (payload[start + 1] & 0x7) &- 1
                    guard type < 16, type.isMultiple(of: 2), temporalID == highestTemporalID else { return false }
                    sawPicture = true
                }
            }
            offset = start + length
        }
        return sawPicture
    }

    func isUnreferenced(_ buffer: CMSampleBuffer) -> Bool {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return false }
        var length = 0
        var total = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &total, dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr, let pointer, length == total else { return false }
        return isUnreferenced(UnsafeRawBufferPointer(start: pointer, count: total))
    }
}
