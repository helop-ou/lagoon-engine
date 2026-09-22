import LagoonPixelOps

/// SIMD pixel primitives kept beside the pinned FFmpeg binaries. FFmpeg emits
/// planar 4:2:0 for several codecs, while Core Video's Apple-recommended
/// outputs are NV12/P010; doing the chroma zip in Swift consumed the software
/// decoder's entire real-time budget on Apple TV.
public enum LagoonPixelConversion {
    public static func interleave420Chroma(
        sourceU: UnsafePointer<UInt8>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt8>,
        sourceVStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        lagoon_interleave_420_chroma(
            sourceU,
            sourceUStride,
            sourceV,
            sourceVStride,
            destination,
            destinationStride,
            width,
            rows
        )
    }

    public static func shift10BitPlaneToP010(
        source: UnsafePointer<UInt16>,
        sourceStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        lagoon_shift_10bit_plane_to_p010(
            source,
            sourceStride,
            destination,
            destinationStride,
            width,
            rows
        )
    }

    public static func interleave420Chroma10BitToP010(
        sourceU: UnsafePointer<UInt16>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt16>,
        sourceVStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        lagoon_interleave_420_chroma_10bit_to_p010(
            sourceU,
            sourceUStride,
            sourceV,
            sourceVStride,
            destination,
            destinationStride,
            width,
            rows
        )
    }
}
